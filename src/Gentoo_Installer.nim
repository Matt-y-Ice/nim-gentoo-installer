## This program automates installation of Gentoo Linux.
## 
## :Author: MattyIce
## :Email: matty_ice_2011@pm.me
## :Copyright: 2025
## 

import std/osproc, std/os, std/strutils, std/terminal

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

proc get_disk(): string =
  ## Prompts the user to select a disk for partitioning and formatting.
  ##
  ## Displays disk information using `lsblk`, then reads user input
  ## from stdin. The returned string should represent a valid block device
  ## (e.g., "/dev/sda").
  ##
  ## :Returns: A string containing the user-provided disk path.
  let disks: string = execProcess("lsblk")
  stdout.styledWriteLine(fgDefault, "[", fgGreen, "INFO", fgDefault, "] ",
    resetStyle, "Disk Information:\n" & disks)
  stdout.styledWriteLine(fgDefault, "[", fgGreen, "INPUT", fgDefault, "] ",
    resetStyle, "Enter disk to partition and format: ")
  let input: string = readline(stdin)
  return input

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

when isMainModule:
  is_sudo()
  stdout.styledWriteLine(fgDefault, "[", fgGreen, "INFO", fgDefault, "] ",
    resetStyle, "Running as root!")
  let disk: string = get_disk()
  part_disk(disk)