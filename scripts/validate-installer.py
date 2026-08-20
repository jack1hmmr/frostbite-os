#!/usr/bin/env python3
"""Validate Frostbite's deliberately narrow Calamares deployment contract."""

from __future__ import annotations

import sys
from pathlib import Path

try:
    import yaml
except ImportError as error:  # pragma: no cover - exercised by build hosts
    raise SystemExit("python-yaml is required to validate installer configuration") from error


REPO_ROOT = Path(__file__).resolve().parent.parent
CALAMARES = REPO_ROOT / "calamares"
MODULES = CALAMARES / "modules"


class UniqueKeyLoader(yaml.SafeLoader):
    """Safe YAML loader which rejects silent duplicate-key overrides."""


def _construct_mapping(loader: UniqueKeyLoader, node: yaml.Node, deep: bool = False) -> dict:
    mapping: dict = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise ValueError(f"duplicate YAML key {key!r} at line {key_node.start_mark.line + 1}")
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
    _construct_mapping,
)


def load_yaml(path: Path):
    try:
        with path.open("r", encoding="utf-8") as stream:
            value = yaml.load(stream, Loader=UniqueKeyLoader)
    except Exception as error:
        raise ValueError(f"{path.relative_to(REPO_ROOT)}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"{path.relative_to(REPO_ROOT)} must contain a YAML mapping")
    return value


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def validate() -> None:
    expected_config_names = {
        "bootloader.conf",
        "finished.conf",
        "fstab.conf",
        "initcpio.conf",
        "keyboard.conf",
        "locale.conf",
        "machineid.conf",
        "mount.conf",
        "partition.conf",
        "services-systemd.conf",
        "shellprocess-finalize.conf",
        "shellprocess-prepare.conf",
        "umount.conf",
        "unpackfs.conf",
        "users.conf",
        "welcome.conf",
    }
    actual_config_names = {path.name for path in MODULES.glob("*.conf")}
    require(
        actual_config_names == expected_config_names,
        f"unexpected Calamares module config set: {sorted(actual_config_names)}",
    )

    configs = {name: load_yaml(MODULES / name) for name in expected_config_names}
    settings = load_yaml(CALAMARES / "settings.conf")
    branding = load_yaml(CALAMARES / "branding/frostbite/branding.desc")

    expected_show = ["welcome", "locale", "keyboard", "partition", "users", "summary"]
    expected_exec = [
        "partition",
        "mount",
        "unpackfs",
        "shellprocess@frostbite-prepare",
        "machineid",
        "fstab",
        "locale",
        "keyboard",
        "localecfg",
        "hwclock",
        "users",
        "shellprocess@frostbite-finalize",
        "initcpio",
        "services-systemd",
        "bootloader",
        "umount",
    ]
    require(settings.get("modules-search") == ["local"], "only local Calamares modules may be searched")
    require(
        settings.get("instances")
        == [
            {
                "id": "frostbite-prepare",
                "module": "shellprocess",
                "config": "shellprocess-prepare.conf",
            },
            {
                "id": "frostbite-finalize",
                "module": "shellprocess",
                "config": "shellprocess-finalize.conf",
            },
        ],
        "the two fail-hard shellprocess instances changed",
    )
    require(
        settings.get("sequence")
        == [{"show": expected_show}, {"exec": expected_exec}, {"show": ["finished"]}],
        "Calamares execution order changed",
    )
    require(settings.get("branding") == "frostbite", "Frostbite branding is not selected")
    for key in ("prompt-install", "dont-chroot", "oem-setup"):
        require(settings.get(key) is False, f"unsafe top-level Calamares value: {key}")
    require(settings.get("disable-cancel") is False, "cancellation must remain available before execution")
    require(
        settings.get("disable-cancel-during-exec") is True,
        "cancellation must be disabled once destructive execution begins",
    )

    welcome = configs["welcome.conf"]
    requirements = welcome.get("requirements", {})
    require(requirements.get("requiredStorage") == 12, "installer minimum disk must remain 12 GiB")
    require(requirements.get("requiredRam") == 3.5, "installer minimum RAM must remain 3.5 GiB")
    require(requirements.get("required") == ["storage", "ram", "root"], "mandatory requirements changed")
    require("internet" not in requirements.get("check", []), "offline installation must not require internet")
    require(welcome.get("geoip") == {"style": "none"}, "welcome GeoIP must remain disabled")

    partition = configs["partition.conf"]
    require(
        partition.get("efi")
        == {
            "mountPoint": "/boot/efi",
            "recommendedSize": "512MiB",
            "minimumSize": "512MiB",
            "label": "EFI",
        },
        "EFI layout changed",
    )
    require(partition.get("userSwapChoices") == ["none"], "swap must remain disabled")
    require(partition.get("initialSwapChoice") == "none", "swap must remain unselected")
    require(partition.get("initialPartitioningChoice") == "none", "erase must require an explicit choice")
    require(partition.get("defaultPartitionTableType") == "gpt", "default partition table must be GPT")
    require(partition.get("requiredPartitionTableType") == "gpt", "partition table must be restricted to GPT")
    require(partition.get("defaultFileSystemType") == "ext4", "root filesystem must be ext4")
    require(partition.get("availableFileSystemTypes") == ["ext4"], "only ext4 may be offered")
    require(partition.get("allowManualPartitioning") is False, "manual partitioning must remain hidden")
    require(partition.get("enableLuksAutomatedPartitioning") is False, "encryption is outside MVP scope")
    require(partition.get("lvm") == {"enable": False}, "LVM is outside MVP scope")

    unpack = configs["unpackfs.conf"].get("unpack")
    require(
        unpack
        == [
            {
                "source": "/run/archiso/bootmnt/frostbite/x86_64/airootfs.sfs",
                "sourcefs": "squashfs",
                "destination": "",
            }
        ],
        "installer must unpack the Frostbite SquashFS without network access",
    )

    prepare = configs["shellprocess-prepare.conf"]
    finalize = configs["shellprocess-finalize.conf"]
    require(prepare == {
        "dontChroot": False,
        "timeout": 120,
        "verbose": True,
        "script": ["/usr/local/bin/frostbite-install-prepare"],
    }, "pre-user cleanup must remain fail-hard inside the target")
    require(finalize == {
        "dontChroot": False,
        "timeout": 600,
        "verbose": True,
        "script": ["/usr/local/bin/frostbite-install-finalize ${USER}"],
    }, "final target audit must remain fail-hard and receive the exact created user")

    users = configs["users.conf"]
    expected_groups = ["wheel", "video", "audio", "input", "storage", "power", "seat"]
    require(
        [item.get("name") for item in users.get("defaultGroups", [])] == expected_groups,
        "installed-user groups changed",
    )
    require(
        all(item.get("must_exist") is True and item.get("system") is True for item in users["defaultGroups"]),
        "installed-user groups must already exist as system groups",
    )
    require(users.get("sudoersGroup") == "wheel", "wheel must control sudo")
    require(users.get("sudoersConfigureWithGroup") is True, "sudo must preserve run-as-group support")
    require(users.get("autologinGroup") == "", "no passwordless-login group may be created")
    require(users.get("displayAutologin") is False and users.get("doAutologin") is True, "TTY1 autologin contract changed")
    require(users.get("setRootPassword") is False, "root must be locked by Calamares")
    require(users.get("doReusePassword") is False, "the user password must not become a root password")
    require(users.get("allowWeakPasswords") is False, "weak passwords must remain disabled")
    require(users.get("allowWeakPasswordsDefault") is False, "weak passwords must not be selected by default")
    require(
        users.get("passwordRequirements")
        == {"minLength": 8, "maxLength": 128, "libpwquality": ["minlen=8"]},
        "installed-user password requirements changed",
    )
    require(users.get("user", {}).get("forbidden_names") == ["root", "frostbite"], "reserved usernames changed")
    require(users.get("user", {}).get("home_permissions") == "0700", "installed home must remain private")
    require(users.get("user", {}).get("nopasswd_group") == "", "passwordless user groups are forbidden")

    services = configs["services-systemd.conf"].get("units", [])
    expected_services = {
        "NetworkManager.service": "enable",
        "NetworkManager-wait-online.service": "disable",
        "fstrim.timer": "enable",
        "seatd.service": "enable",
        "frostbite-firstboot.service": "enable",
        "frostbite-performance.service": "enable",
        "getty@tty1.service": "enable",
    }
    require(
        {item.get("name"): item.get("action") for item in services} == expected_services,
        "installed service policy changed",
    )
    require(all(item.get("mandatory") is True for item in services), "service changes must fail the install on error")

    require(configs["initcpio.conf"] == {"kernel": "linux-zen", "be_unsafe": False}, "normal linux-zen initramfs contract changed")
    bootloader = configs["bootloader.conf"]
    require(bootloader.get("efiBootLoader") == "grub", "UEFI bootloader must be GRUB")
    require(bootloader.get("efiBootloaderId") == "Frostbite", "UEFI bootloader ID changed")
    require(bootloader.get("installEFIFallback") is True, "removable-media UEFI fallback is mandatory")
    require(bootloader.get("installHybridGRUB") is False, "BIOS hybrid installation is outside scope")
    require(configs["umount.conf"] == {"emergency": True}, "failed installs must unmount safely")

    require(branding.get("componentName") == "frostbite", "branding component name changed")
    require(branding.get("slideshow") == ["logo.svg"], "non-QML image slideshow changed")
    require(
        set(branding.get("style", {}))
        == {"SidebarBackground", "SidebarText", "SidebarTextCurrent", "SidebarBackgroundCurrent"},
        "Calamares branding style keys changed",
    )
    require((CALAMARES / "branding/frostbite/stylesheet.qss").is_file(), "stylesheet.qss is missing")
    require(not (CALAMARES / "branding/frostbite/style.qss").exists(), "obsolete style.qss must not return")

    airootfs = REPO_ROOT / "archiso/airootfs"
    profile = (REPO_ROOT / "archiso/profiledef.sh").read_text(encoding="utf-8")
    normal_sway = (airootfs / "etc/skel/.config/sway/config").read_text(encoding="utf-8")
    installer_sway_path = "/etc/sway/frostbite-installer.conf"
    installer_sway = (airootfs / installer_sway_path.lstrip("/")).read_text(encoding="utf-8")
    session_script = (airootfs / "usr/local/bin/frostbite-session").read_text(encoding="utf-8")
    prepare_script = (airootfs / "usr/local/bin/frostbite-install-prepare").read_text(encoding="utf-8")
    finalize_script = (airootfs / "usr/local/bin/frostbite-install-finalize").read_text(encoding="utf-8")
    customize_script = (airootfs / "root/customize_airootfs.sh").read_text(encoding="utf-8")
    vm_audit_script = (REPO_ROOT / "scripts/audit-installed-vm.sh").read_text(encoding="utf-8")
    safety_patch = (REPO_ROOT / "packaging/calamares-frostbite/frostbite-erase-only.patch").read_text(
        encoding="utf-8"
    )
    existing_user_patch = (
        REPO_ROOT / "packaging/calamares-frostbite/frostbite-existing-user.patch"
    ).read_text(encoding="utf-8")

    polkit_rule = "/etc/polkit-1/rules.d/49-frostbite-live-installer.rules"
    require(
        f'  ["{polkit_rule}"]="0:0:644"' in profile,
        "live installer polkit rule must be root-owned mode 0644",
    )
    require(polkit_rule in prepare_script, "prepare cleanup must remove the live polkit rule")
    require(
        f'  ["{installer_sway_path}"]="0:0:644"' in profile,
        "dedicated installer Sway config must be root-owned mode 0644",
    )
    require(
        "exec sway --config \"$installer_sway_config\"" in session_script
        and f'installer_sway_config="{installer_sway_path}"' in session_script,
        "the dedicated boot mode must use the isolated installer Sway config",
    )
    require(
        "set $installer frostbite-installer" in installer_sway
        and "bindsym $mod+i exec $installer" in installer_sway
        and "exec $installer" in installer_sway,
        "the isolated Sway session must launch exactly the guarded installer wrapper",
    )
    unsafe_installer_bindings = (
        " kill",
        " reload",
        "swaymsg exit",
    )
    require(
        not any(
            token in line
            for line in installer_sway.splitlines()
            if line.lstrip().startswith("bind")
            for token in unsafe_installer_bindings
        ),
        "the destructive installer session must not expose kill, reload, or exit bindings",
    )
    require(
        "exec $steam" in normal_sway
        and "frostbite-installer" not in normal_sway
        and "frostbite.install=1" not in normal_sway,
        "ordinary live and installed Sway sessions must remain Steam-only",
    )
    require(installer_sway_path in finalize_script, "target cleanup must remove the live-only Sway config")
    require(
        "/root/customize_airootfs.sh" in finalize_script
        and "[[ ! -e /root/customize_airootfs.sh ]]" in finalize_script
        and "/root/customize_airootfs.sh" in vm_audit_script,
        "the known-password image customization script must be absent and audited in the target",
    )
    require(
        f"[[ ! -e {polkit_rule} ]]" in finalize_script,
        "final target audit must prove the live polkit rule is absent",
    )
    require(
        "[[ ! -e /usr/share/polkit-1/actions/io.calamares.calamares.policy ]]" in finalize_script,
        "final target audit must prove Calamares policy residue is absent",
    )
    for script_name, account_script in (
        ("prepare cleanup", prepare_script),
        ("final target audit", finalize_script),
        ("booted-VM audit", vm_audit_script),
    ):
        require(
            '$1 == "UID_MIN"' in account_script and '$1 == "UID_MAX"' in account_script,
            f"{script_name} must derive the normal-user range from /etc/login.defs",
        )
        require(
            '$3 >= uid_min && $3 <= uid_max' in account_script,
            f"{script_name} must include both configured UID range endpoints",
        )
    require("${#normal_users[@]} != 0" in prepare_script, "prepare normal-user count must be zero")
    require("${#normal_users[@]} != 1" in finalize_script, "installed normal-user count must be exactly one")
    require(
        "^[a-z_][a-z0-9_-]{0,30}$" in finalize_script,
        "finalizer username length must match Calamares's 31-character maximum",
    )
    require(
        "rm -f /var/lib/pacman/sync/frostbite-build.db*" in finalize_script
        and "build-local pacman repository metadata survived" in finalize_script,
        "target cleanup must remove and verify build-local repository metadata",
    )
    require("usermod -p '!' root" in customize_script, "live root must be locked at image creation")
    require("passwd -d root" not in customize_script, "empty live root passwords are forbidden")
    require(
        '-static const QRegularExpression USERNAME_RX( "^[a-z_][a-z0-9_-]*[$]?$" )' in safety_patch
        and '+static const QRegularExpression USERNAME_RX( "^[a-z_][a-z0-9_-]*$" )' in safety_patch,
        "Calamares UI and finalizer username policies must agree",
    )
    require(
        "::getpwnam( loginNameBytes.constData() )" in existing_user_patch,
        "Calamares must reject existing live/system account names before execution",
    )
    require(
        "::getgrnam( loginNameBytes.constData() )" in existing_user_patch,
        "Calamares must reject existing group names before useradd -U can fail",
    )
    pkgbuild = (REPO_ROOT / "packaging/calamares-frostbite/PKGBUILD").read_text(encoding="utf-8")
    require("pkgver=3.4.2" in pkgbuild, "the reviewed Calamares release pin changed")
    require(
        "733bbbb00dc9f84874bd5c22960952f317ea2537565431179fa2152b2fbfdccc" in pkgbuild,
        "the reviewed Calamares 3.4.2 source checksum changed",
    )
    require(
        'url=\'https://codeberg.org/Calamares/calamares\'' in pkgbuild,
        "the reviewed upstream Calamares source changed",
    )
    require("  'parted'" in pkgbuild, "libparted must remain a hard dependency of the storage safety gate")
    require(
        "-DWITHOUT_LIBPARTED" in pkgbuild and "build/compile_commands.json" in pkgbuild,
        "the Calamares build must fail when its storage safety check is compiled out",
    )


if __name__ == "__main__":
    try:
        validate()
    except ValueError as error:
        print(f"installer validation failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
    print("installer configuration matches the Frostbite MVP safety contract")
