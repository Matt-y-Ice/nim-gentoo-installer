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
  let uid = strip(execProcess("id -u"))
  if uid != "0":
    stdout.styledWriteLine(fgRed,
      "You must have root privileges to continue; " & 
      "Restarting as root!")
    let script = getAppFilename()
    discard execShellCmd("sudo " & script)
    quit(0)

proc get_disk(): string =
  let disks = execProcess("lsblk")
  stdout.styledWriteLine(fgDefault, "[", fgGreen, "INFO", fgDefault, "] ",
    resetStyle, "Disk Information:\n" & disks)
  stdout.styledWriteLine(fgDefault, "[", fgGreen, "INPUT", fgDefault, "] ",
    resetStyle, "Enter disk to partition and format: ")
  let input = readline(stdin)
  return input

proc part_disk(disk: string) =
  let errWipe = execCmd("wipefs --all " & disk)
  if errWipe != 0:
    stdout.styledWriteLine(fgRed,
      "Error: Program failed to wipe disk!")
    quit(1)
  else:
    let partCmd = "echo -e 'size=1G, type=U\nsize=4G, type=S\nsize=+' | " &
      "sfdisk --label=gpt " & disk 
    let errPart = execShellCmd(partCmd)
    if errPart != 0:
      stdout.styledWriteLine(fgRed,"Error: Partitioning failed!")
      quit(1)
    else:
      stdout.styledWriteLine(fgGreen, "Disk partitioned successfully.")

when isMainModule:
  is_sudo()
  stdout.styledWriteLine(fgDefault, "[", fgGreen, "INFO", fgDefault, "] ",
    resetStyle, "Running as root!")
  let disk = get_disk()
  part_disk(disk)