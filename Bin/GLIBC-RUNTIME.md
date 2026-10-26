# Private Soloist runtime

Spotify's current Soloist builds require glibc 2.38 or newer. The plugin
therefore runs only the Soloist process through architecture-matched runtime
libraries from Debian 13 (glibc 2.41). It does not install or replace any
system library.

The files under each `Bin/*/glibc/` directory were extracted from these
official Debian packages:

- `libc6_2.41-12+deb13u4_{amd64,armhf,arm64}.deb`
- `libgcc-s1_14.2.0-19_{amd64,armhf,arm64}.deb`
- `libatomic1_14.2.0-19_{amd64,armhf,arm64}.deb`

Package sources:

- https://deb.debian.org/debian/pool/main/g/glibc/
- https://deb.debian.org/debian/pool/main/g/gcc-14/

Corresponding glibc source:

- https://deb.debian.org/debian/pool/main/g/glibc/glibc_2.41.orig.tar.xz
- https://deb.debian.org/debian/pool/main/g/glibc/glibc_2.41-12+deb13u4.debian.tar.xz

SHA-256 checksums of the binary packages used:

```text
967aa62605721081c3eb2a17650611a792aa802d76a6511d1840242623d204c9  libc6_2.41-12+deb13u4_amd64.deb
4fc6fed8d77d01c0dacb5fda8b880a8c8a669575936de5761b693077a6f6c2ec  libc6_2.41-12+deb13u4_armhf.deb
8784eda966b189c777a384dac5ce009e8fc9b52d006926c5a013e7fa8aa688cc  libc6_2.41-12+deb13u4_arm64.deb
3c71917b490d1a17aed43196a2787a256ecf060526cdb20216a74bedc061b150  libgcc-s1_14.2.0-19_amd64.deb
25910c3a0bce3985e388de445244578b7922dc670c9bba1c8673779b89447873  libgcc-s1_14.2.0-19_armhf.deb
1108bc87879833d6d9a145f22a4a15cddb34e065b4b5f4b97bee586adbac2851  libgcc-s1_14.2.0-19_arm64.deb
212b399aae2f7299203d261a57e49372e09565a9a5ea971905f94a3960366c05  libatomic1_14.2.0-19_amd64.deb
e4a4dc17913ded43f2a8571f9c8c214d05534632fc5a41705d6b39acd8d5f4a4  libatomic1_14.2.0-19_armhf.deb
7ccff90234484bf21ae5ecb79d25b6a84b2f4038f65dd139085b2e3a937cd8dc  libatomic1_14.2.0-19_arm64.deb
```

The Debian/glibc copyright and license text is included as
`Bin/glibc-copyright`.
