## `ddb_vfs_archivemount`

a deadbeef plugin for better archive support

it uses FUSE filesystems written by others to mount archives and serve files from there

this is better than using `<archiving library>` directly because:
- the job of providing a filesystem-like api on top of the library is already done by the fuse filesystem
- caching of read file data is handled by the kernel
- i can't find the documentation for the unrar library

the filesystems used are:
- [rar2fs] ([unrar])
  - best handling of rar archives due to using original unrar code
  - *note: compile with the same version of unrar as listed on their website, otherwise your archives might come up as empty*
- [fuse-archive] ([libarchive])
  - less strict zip reader than deadbeef's default `libzip` one, opens some archives it refuses to (example: mega.nz "download as zip" ones)
  - 7z reading works but is slow, wonder if there's anything better for it

despite the name, it doesn't actually use [archivemount] (anymore) - some 7z archives would come up as empty with it so i found [fuse-archive] as an alternative which also claims to be faster

[rar2fs]: https://github.com/hasse69/rar2fs
[unrar]: https://www.rarlab.com/

[fuse-archive]: https://github.com/google/fuse-archive
[libarchive]: https://github.com/libarchive/libarchive

[archivemount]: https://github.com/cybernoid/archivemount

## mandatory section for compiling dependencies

```sh
cd ~/git
git clone --depth=1 https://github.com/google/fuse-archive
cd fuse-archive
make CXXFLAGS='-O2 -g'
ln -s $PWD/out/fuse-archive ~/.local/bin/
```

```sh
cd ~/Downloads
curl https://www.rarlab.com/rar/unrarsrc-6.0.3.tar.gz | tar -xvzf-
cd unrar
make lib CXXFLAGS='-O2 -g -fPIC'

cd ~/git
git clone --depth=1 https://github.com/hasse69/rar2fs
cd rar2fs
autoreconf -si
./configure --with-unrar=$HOME/Downloads/unrar
ln -s $PWD/src/rar2fs ~/.local/bin/
```
