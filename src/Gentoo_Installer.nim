## This program automates installation of Gentoo Linux.
## 
## :Author: MattyIce
## :Email: matty_ice_2011@pm.me
## :Copyright: 2025

import std/osproc, std/os, std/strutils, std/terminal, std/tables, std/sequtils
import parsetoml # third party

proc is_sudo() =
  ## Ensures the program is running with root privileges.
  ## Restarts the script with `sudo` if not already root.
  ## Exits the program after restarting if not run as root.
  eraseScreen()
  let uid: string = strip(execProcess("id -u"))
  if uid != "0":
    stdout.styledWriteLine(fgRed,
      "You must have root privileges to continue; " & 
      "Restarting as root!")
    let script = getAppFilename()
    discard execShellCmd("sudo " & script)
    quit(0)

proc getStrSeq(value: TomlValueRef): seq[string] =
  ## Converts a TOML array value into a sequence of strings.
  ##
  ## This helper procedure is used to extract a list of strings from a
  ## `TomlValueRef` representing a TOML array (e.g., lists of packages or groups).
  ##
  ## :Parameters:
  ##   - `value`: A `TomlValueRef` representing a TOML array.
  ##
  ## :Returns: A `seq[string]` containing all elements from the array as strings.

  for item in value.getElems():
    result.add(item.getStr())

proc load_config(path: string): tuple[
  disk, hostname, username, desktop: string,
  usergroups: seq[string],
  allPkgs: seq[string]
] =
  ## Loads and parses a TOML configuration file for the Gentoo installer.
  ##
  ## This procedure reads and parses a TOML config file, extracting values such as
  ## the target disk, hostname, username, user groups, selected desktop environment,
  ## and categorized package lists. All selected packages are combined into a single
  ## sequence for downstream installation.
  ##
  ## :Parameters:
  ##   - `path`: Path to the TOML configuration file (e.g., "gnome.toml").
  ##
  ## :Returns: A tuple containing:
  ##   - `disk`: Target disk device (e.g., "/dev/sda")
  ##   - `hostname`: Desired system hostname
  ##   - `username`: Default user to create
  ##   - `desktop`: Selected desktop environment key (e.g., "gnome")
  ##   - `usergroups`: List of groups the user should belong to
  ##   - `allPkgs`: Combined list of system, desktop, apps, and font packages to install
  let config = parsetoml.parseFile(path)

  result.disk = config["disk"].getStr()
  result.hostname = config["hostname"].getStr()
  result.username = config["username"].getStr()
  result.usergroups = getStrSeq(config["usergroups"])
  result.desktop = config["desktop"].getStr()

  let 
    packages = config["packages"]
    systemPkgs  = getStrSeq(packages["system"])
    desktopPkgs = getStrSeq(packages[result.desktop])
    appsPkgs    = getStrSeq(packages["apps"])
    fonts       = getStrSeq(packages["fonts"])

  stdout.styledWriteLine(fgCyan, "Using profile:")
  echo "Disk: ", result.disk
  echo "Hostname: ", result.hostname
  echo "User: ", result.username, " Groups: ", result.usergroups
  echo "Desktop: ", result.desktop
  echo "Packages (", result.allPkgs.len, " total):"
  echo "  ", result.allPkgs.join(" ")

  result.allPkgs = systemPkgs & desktopPkgs & appsPkgs & fonts

proc part_disk(disk: string) =
  ## Partitions the specified disk using GPT and predefined layout.
  ##
  ## First wipes all filesystem signatures on the disk using `wipefs`.
  ## Then partitions the disk using `sfdisk` with the following layout:
  ## - 1 GiB EFI partition (type U)
  ## - 4 GiB swap partition (type S)
  ## - Remaining space as root partition
  ##
  ## If either command fails, the program exits with status code 1.
  ##
  ## :Parameters:
  ##   - `disk`: The full path to the disk device to partition (e.g., "/dev/sda").
  let errWipe: int = execCmd("wipefs --all " & disk)
  if errWipe != 0:
    stdout.styledWriteLine(fgRed,
      "Error: Program failed to wipe disk!")
    quit(1)
  else:
    let partCmd: string = "echo -e 'size=1G, type=U\nsize=4G, type=S\nsize=+' | " &
      "sfdisk --label=gpt " & disk 
    let errPart: int = execShellCmd(partCmd)
    if errPart != 0:
      stdout.styledWriteLine(fgRed,"Error: Partitioning failed!")
      quit(1)
    else:
      stdout.styledWriteLine(fgGreen, "Disk partitioned successfully.")

proc format_disk(part1: string, part2: string, part3: string) =
  ## Formats the specified partitions for EFI, swap, and root.
  ##
  ## - `part1`: EFI partition (formatted as FAT32)
  ## - `part2`: Swap partition (formatted with `mkswap`)
  ## - `part3`: Root partition (formatted as Btrfs)
  ##
  ## If any formatting command fails, the program prints an error
  ## message and exits with code 1.
  let errFat = execCmd("mkfs.fat -F32 " & part1)
  if errFat != 0:
    stdout.styledWriteLine(fgRed, "Error: Failed to format EFI Partition!")
    quit(1)
  let errSwap = execCmd("mkswap " & part2)
  if errSwap != 0:
    stdout.styledWriteLine(fgRed, "Error: Failed to format Swap Partition!")
    quit(1)
  let errBtrfs = execCmd("mkfs.btrfs -f " & part3)
  if errBtrfs != 0:
    stdout.styledWriteLine(fgRed, "Error: Failed to format BTRFS Partition!")
    quit(1)

proc setup_subvolumes(rPart: string, mountPt: string) =
  ## Creates and initializes Btrfs subvolumes on the given root partition.
  ##
  ## Mounts the root partition at the specified mount point, then creates
  ## the following subvolumes:
  ##   - @
  ##   - @home
  ##   - @var
  ##   - @tmp
  ##   - @.snapshots
  ##
  ## After creation, the root partition is unmounted. If any command fails,
  ## the program prints an error message and exits with code 1.
  ##
  ## :Parameters:
  ##   - `rPart`: The Btrfs-formatted root partition device (e.g., "/dev/sda3")
  ##   - `mountPt`: Temporary mount point used for creating subvolumes (e.g., "/mnt/gentoo")
  if not dirExists(mountPt):
    createDir(mountPt)
  let mntErr = execCmd("mount " & rPart & " " & mountPt)
  if mntErr != 0:
    stdout.styledWriteLine(fgRed,
      "Error: Failed to mount Btrfs root partition!")
    quit(1)
  for sub in ["@", "@home", "@var", "@tmp", "@.snapshots"]:
    stdout.styledWriteLine(fgCyan, "Creating subvolume: " & sub)
    let err = execCmd("btrfs subvolume create " & mountPt & "/" & sub)
    if err != 0:
      stdout.styledWriteLine(fgRed, 
        "Error: Failed to create Btrfs subvolume: " & sub & "!")
      quit(1)
  discard execCmd("umount " & rPart)
  stdout.styledWriteLine(fgGreen, "Created Btrfs subvolumes succesfully.")

proc mount_subvolumes(rPart: string, baseMount: string) =
  ## Mounts Btrfs subvolumes to their respective mount points.
  ##
  ## This includes:
  ##   - `@`      → `/mnt/gentoo`
  ##   - `@home`  → `/mnt/gentoo/home`
  ##   - `@var`   → `/mnt/gentoo/var`
  ##   - `@tmp`   → `/mnt/gentoo/tmp`
  ##   - `@.snapshots` → `/mnt/gentoo/.snapshots`
  ##
  ## All mounts use recommended Btrfs options: noatime, compress=zstd.
  ##
  ## :Parameters:
  ##   - `rPart`: The device path of the Btrfs partition (e.g., "/dev/sda3")
  ##   - `baseMount`: Root of where Gentoo is being installed (e.g., "/mnt/gentoo")
  let subvols: Table[string, string] = {
    "@": "",
    "@home": "/home",
    "@var": "/var",
    "@tmp": "/tmp",
    "@.snapshots": "/.snapshots"
  }.toTable()

  for sub, path in subvols:
    let fullMount = baseMount & path
    if not dirExists(fullMount):
      createDir(fullMount)

    let opts = "-o noatime,compress=zstd,subvol=" & sub
    let err = execCmd("mount " & opts & " " & rPart & " " & fullMount)
    if err != 0:
      stdout.styledWriteLine(fgRed, "Error: Failed to mount subvolume " & sub)
      quit(1)
    else:
      stdout.styledWriteLine(fgGreen, "Mounted subvolume " & sub & " to " & fullMount)

proc enable_swap(swapP: string) =
  ## Activates the swap partition using the `swapon` command.
  ##
  ## This function enables the specified swap partition so that the
  ## system can use it for virtual memory. If the command fails, an
  ## error message is printed, but the program does not exit.
  ##
  ## :Parameters:
  ##   - `swapP`: The device path of the swap partition (e.g., "/dev/sda2")
  let errSwap = execCmd("swapon " & swapP)
  if errSwap != 0:
    stdout.styledWriteLine(fgRed, "Error: Failed to activate swap partition!")
  else:
    stdout.styledWriteLine(fgGreen, "Activated swap partition successfully!")

when isMainModule:
  is_sudo()
  stdout.styledWriteLine(fgDefault, "[", fgGreen, "INFO", fgDefault, "] ",
    resetStyle, "Running as root!")
  
  let (
    disk,
    hostname, 
    username, 
    desktop,
    usergroups,
    allPkgs
    ) = load_config("gnome.toml")

  part_disk(disk)

  let 
    efi: string = disk & "1"
    swapP: string = disk & "2"
    root: string = disk & "3"
  
  format_disk(efi, swapP, root)
  setup_subvolumes(root, "/mnt/gentoo")
  mount_subvolumes(root, "/mnt/gentoo")
  enable_swap(swapP)
