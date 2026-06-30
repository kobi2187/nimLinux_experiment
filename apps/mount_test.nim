# Test app: mount FAT disk and read first sector
import ../fs/fatfs

proc main() =
  echo "mount_test: starting"
  if fsMount():
    echo "mount_test: FAT mounted"
  else:
    echo "mount_test: mount failed — DMA timeout"

main()
