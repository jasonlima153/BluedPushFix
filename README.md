# BluedPushFix - 纯内存音频保活推送修复

基于 Blued极速版2 IPA 逆向分析报告的推送保活 Tweak。

## 特性

- **零外部文件依赖**：无声音频通过 `xxd` 转换为 C 数组，编译时直接嵌入二进制
- **内存加载音频**：避开 iOS 文件系统权限与多开分身路径变化问题
- **深度 Hook 守护**：拦截 gRPC、BDLiveIM、BDPartyController、个推 SDK 的后台断连行为
- **全自动构建**：GitHub Actions 自动编译，每次 push 自动生成 dylib

## 项目结构

```
BluedPushFix/
├── Tweak.xm              # 主 Tweak 源码（内存音频 + Hook 逻辑）
├── Makefile              # Theos 编译配置
├── silent.mp3            # 无声音频源文件（编译前由 xxd 转为 silent_data.h）
├── silent_data.h         # 自动生成的 C 数组头文件（GitHub Actions 生成）
├── .github/
│   └── workflows/
│       └── build.yml     # GitHub Actions 自动构建工作流
└── README.md
```

## 自动构建流程

1. 推送代码到 GitHub
2. GitHub Actions 自动：
   - 安装 Theos 环境
   - 下载 iOS SDK
   - 用 `xxd -i silent.mp3 silent_data.h` 生成内存数组头文件
   - 编译生成 `BluedPushFix.dylib`
   - 上传构建产物为 Artifact

## 使用方法

将编译出的 `BluedPushFix.dylib` 通过任意签名工具（Sideloadly、轻松签、optool）注入到分身 IPA 的主二进制中即可。

## 技术原理

详见 [Blued推送服务分析报告](https://github.com/jasonlima153/bu/blob/main/Blued推送服务分析报告.docx)
