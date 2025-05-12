## This program automates installation of Gentoo Linux.
## 
## :Author: MattyIce
## :Email: matty_ice_2011@pm.me
## :Copyright: 2025

import std/osproc, std/os, std/strutils, std/terminal, std/tables, std/httpclient
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

proc dl_stage3(address: string, mountPt: string) =
  ## Downloads the Gentoo stage3 tarball to the specified mount point.
  ##
  ## :Parameters:
  ##   - `address`: The full HTTPS URL to the stage3 tarball.
  ##   - `mountPt`: The target mount point (e.g., "/mnt/gentoo") where
  ##                the tarball should be saved as "stage3.tar.xz".
  ##
  ## This procedure uses Nim's built-in HTTP client to download the file directly
  ## to disk. It handles cleanup by closing the client in a `finally` block.
  var client = newHttpClient()
  stdout.styledWriteLine(
    fgCyan, "Downloading stage3 tarball from " & address & "..."
    )
  try:
    client.downloadFile(address, mountPt & "/stage3.tar.xz")
  finally:
    client.close()
    stdout.styledWriteLine(fgGreen, "Download complete!")

proc install_stage3(mountPt: string) = 
  ## Extracts and installs the Gentoo Stage3 tarball to the specified mount point.
  ##
  ## This procedure runs the `tar` command with options tailored for Gentoo's
  ## Stage3 archives. It ensures extended attributes are preserved and numeric
  ## user IDs are used for proper system setup.
  ##
  ## :Parameters:
  ##   - `mountPt`: The root directory where the Stage3 tarball should be extracted,
  ##                typically something like "/mnt/gentoo".
  ##
  ## The procedure prints progress messages and exits with code 1 if extraction fails.
  let tarCmd: string = "tar xpvf /mnt/gentoo/stage3.tar.xz --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo"
  if not fileExists(mountPt & "/stage3.tar.xz"):
    stdout.styledWriteLine(fgRed, "Error: Stage3 tarball not found.")
    quit(1)
  stdout.styledWriteLine(
    fgCyan, "Extracting and installing stage3 tarball..."
    )
  let err = execCmd(tarCmd)
  if err != 0:
    stdout.styledWriteLine(fgRed, "Error: Failed to extract stg3 tarball!")
    quit(1)
  else:
    stdout.styledWriteLine(fgGreen, "Stage3 file succesfully installed!")

proc prepare_chroot(disk: string, mountPt: string, makeConfig: string) = 
  ## Prepares the Gentoo chroot environment by copying configuration files,
  ## mounting necessary filesystems, and applying the provided make.conf.
  ##
  ## :Parameters:
  ##   - `disk`: The target disk (e.g., "/dev/sdc") used for setting up chroot variables.
  ##   - `mountPt`: The root mount point for the new system (e.g., "/mnt/gentoo").
  ##   - `makeConfig`: Path to the make.conf file to copy into the new system.
  let commands: seq[string] = @[
    "echo 'disk=\"" & disk & "\"' > " & mountPt & "/root/chroot_var.sh",
    "cp --dereference /etc/resolv.conf " & mountPt & "/etc",
    "mount --types proc /proc " & mountPt & "/proc",
    "mount --rbind /sys " & mountPt & "/sys",
    "mount --make-rslave " & mountPt & "/sys",
    "mount --rbind /dev " & mountPt & "/dev",
    "mount --make-rslave " & mountPt & "/dev",
    "mount --bind /run " & mountPt & "/run",
    "mount --make-slave " & mountPt & "/run",
  ]

  try:
    let content = readFile(makeConfig)
    writeFile(mountPt & "/etc/portage/make.conf", content)
    stdout.styledWriteLine(fgGreen, "make.conf successfully written.")
  except OSError:
    stdout.styledWriteLine(fgRed, "Error: make.conf failed to write!")
    quit(1)

  for cmd in commands:
    stdout.styledWriteLine(fgCyan, "Executing: " & cmd)
    let err = execCmd(cmd)
    if err != 0:
      stdout.styledWriteLine(fgRed, "Error: " & cmd & " failed to execute!")
      quit(1)

  stdout.styledWriteLine(fgGreen, "Successfully prepared for chroot.")

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
    mountPoint: string = "/mnt/gentoo"
  
  format_disk(efi, swapP, root)
  setup_subvolumes(root, mountPoint)
  mount_subvolumes(root, mountPoint)
  enable_swap(swapP)
  
  #TODO: add address to TOML and parser
  let stage3Addy: string = "https://distfiles.gentoo.org/releases/amd64/autobuilds/20250511T165428Z/stage3-amd64-desktop-systemd-20250511T165428Z.tar.xz"

  dl_stage3(stage3Addy, mountPoint)
  install_stage3(mountPoint)

  let makeConfig: string = "../gentoo-files/make.conf"
  prepare_chroot(root, mountPoint, makeConfig)
