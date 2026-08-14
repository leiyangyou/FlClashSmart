<div>

[**简体中文**](README_zh_CN.md)

</div>

> [!IMPORTANT]
> **💡 About this Custom Fork**
> 
> This project is based on [FlClash](https://github.com/chen08209/FlClash) and integrates the [mihomo](https://github.com/vernesong/mihomo) core, adding **'Smart' routing policy** (intelligent node selection).

## FlClash

[![Downloads](https://img.shields.io/github/downloads/Satar07/FlClashSmart/total?style=flat-square&logo=github)](https://github.com/Satar07/FlClashSmart/releases/)[![Last Version](https://img.shields.io/github/release/Satar07/FlClashSmart/all.svg?style=flat-square)](https://github.com/Satar07/FlClashSmart/releases/)[![License](https://img.shields.io/github/license/Satar07/FlClashSmart?style=flat-square)](LICENSE)

A multi-platform proxy client based on ClashMeta, simple and easy to use, open-source and ad-free.

<p align="center">
    <picture>
        <source media="(prefers-color-scheme: dark)" srcset="snapshots/preview-dark.png">
        <img alt="FlClash on desktop and mobile" src="snapshots/preview.png" width="90%">
    </picture>
</p>

## Features

✈️ Multi-platform: Android, Windows, macOS and Linux

💻 Adaptive multiple screen sizes, Multiple color themes available

💡 Based on Material You Design, [Surfboard](https://github.com/getsurfboard/surfboard)-like UI

☁️ Supports data sync via WebDAV

✨ Support subscription link, Dark mode

## Use

### Linux

⚠️ Make sure to install the following dependencies before using them

   ```bash
    sudo apt-get install libayatana-appindicator3-dev
   ```

### Android

Support the following actions

   ```bash
    com.flsmart.clash.action.START
    
    com.flsmart.clash.action.STOP
    
    com.flsmart.clash.action.TOGGLE
   ```

## Download

<a href="https://github.com/Satar07/FlClashSmart/releases"><img alt="Get it on GitHub" src="snapshots/get-it-on-github.svg" width="200px"/></a>

## Build

1. Update submodules
   ```bash
   git submodule update --init --recursive
   ```

2. Install `Flutter` and `Golang` environment

3. Build Application

    - android

        1. Install `Android SDK`, `Android NDK`

        2. Set `ANDROID_NDK` environment variable

        3. Run build script

           ```bash
           dart setup.dart android
           ```

    - windows

        1. Requires a Windows client

        2. Install `GCC`, `Inno Setup`

        3. Run build script

           ```bash
           dart setup.dart windows
           ```

    - linux

        1. Requires a Linux client

        2. Dependencies are auto-installed by setup script, or manually:
           ```bash
           sudo apt-get install -y libayatana-appindicator3-dev
           ```

        3. Run build script

           ```bash
           dart setup.dart linux
           ```

    - macOS

        1. Requires a macOS client

        2. Run build script

           ```bash
           dart setup.dart macos
           ```

## Star

The easiest way to support developers is to click on the star (⭐) at the top of the page.

<p style="text-align: center;">
    <a href="https://api.star-history.com/svg?repos=Satar07/FlClashSmart&Date">
        <img alt="start" width=50% src="https://api.star-history.com/svg?repos=Satar07/FlClashSmart&Date"/>
    </a>
</p>
