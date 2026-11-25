# Third-party notices

[简体中文](THIRD_PARTY_NOTICES.md) · English

The installer bundles the following Python runtime and principal dependencies. Consult the build script and the installer itself for the versions in a particular distribution.

| Component | Version | License |
| --- | --- | --- |
| [CPython](https://www.python.org/downloads/release/python-31216/) | 3.12.16 | [Python Software Foundation License Agreement](https://docs.python.org/3.12/license.html) and bundled third-party terms |
| [APSW](https://github.com/rogerbinns/apsw) | 3.54.1.0 | [APSW license](https://github.com/rogerbinns/apsw/blob/master/LICENSE). The distribution metadata uses `any-OSI`. |
| [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) | 11.63.1 | [GPL-3.0-or-later](https://pypi.org/project/pymobiledevice3/11.63.1/) |
| [makelive](https://github.com/RhetTbull/makelive) | 0.7.0 | [MIT](https://github.com/RhetTbull/makelive/blob/main/LICENSE) |

The implementation of multi-library access draws on research into macOS Photos interfaces by [RhetTbull/photokit](https://github.com/RhetTbull/photokit). The app calls the system framework from Objective-C.

Before redistributing an installer, review the licenses, versions and required notices for the direct and transitive dependencies actually bundled in it. The installer includes the GPL-licensed pymobiledevice3. Check that the distribution and licensing choices are compatible, and provide license texts and corresponding source as required. These notices describe third-party components. The project’s own code is released under GPL-3.0-or-later. [Project license](LICENSE)
