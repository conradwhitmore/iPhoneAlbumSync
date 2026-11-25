# 第三方依赖

简体中文 · [English](THIRD_PARTY_NOTICES.en.md)

以下为安装包直接携带的 Python 运行环境及主要依赖。版本以构建脚本和实际安装包为准。

| 项目 | 目前版本 | 许可证 |
| --- | --- | --- |
| [CPython](https://www.python.org/downloads/release/python-31216/) | 3.12.16 | [Python Software Foundation License Agreement](https://docs.python.org/3.12/license.html) 及随附的第三方条款 |
| [APSW](https://github.com/rogerbinns/apsw) | 3.54.1.0 | [APSW LICENSE](https://github.com/rogerbinns/apsw/blob/master/LICENSE)，发行包标识 `any-OSI` |
| [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) | 11.63.1 | [GPL‑3.0-or-later](https://pypi.org/project/pymobiledevice3/11.63.1/) |
| [makelive](https://github.com/RhetTbull/makelive) | 0.7.0 | [MIT](https://github.com/RhetTbull/makelive/blob/main/LICENSE) |

PhotoKit 的多图库访问参考了 [RhetTbull/photokit](https://github.com/RhetTbull/photokit) 对 macOS 接口的研究。App 自身使用 Objective‑C 调用系统框架。

对外分发含依赖的安装包时，应以实际构建产物为准核对所有直接及传递依赖的许可证、版本和随附声明。由于安装包包含 GPL 的 `pymobiledevice3`，分发前应确认项目的兼容授权及发行方式，并按适用条款提供许可证文本与对应源码。项目自身代码采用 GPL-3.0-or-later。[项目许可证](LICENSE)
