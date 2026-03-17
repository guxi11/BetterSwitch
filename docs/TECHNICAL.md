# BetterSwitch - Technical Documentation

## Product Requirements

### Overview

A macOS menu bar app that automatically switches monitor input source when a Bluetooth keyboard connects.

### Problem

When using one monitor with multiple Macs and a Bluetooth keyboard that can switch between devices, users must manually switch the monitor input every time they switch keyboards.

### Solution

Detect Bluetooth keyboard connection events and automatically send DDC/CI commands to switch the monitor to the corresponding input source.

## Core Features

### 1. Bluetooth Keyboard Detection

- Monitor for specific Bluetooth keyboard connect/disconnect events
- Identify keyboard by device name or Bluetooth ID
- Support both Classic Bluetooth and BLE keyboards

### 2. DDC/CI Input Switching

- Send DDC/CI commands to switch monitor input source
- Support common inputs: HDMI1, HDMI2, DisplayPort, USB-C, etc.
- Uses m1ddc for Apple Silicon compatibility

### 3. Configuration

- Map keyboard connection → specific input source
- Example: "When MX Keys connects → switch to HDMI1"

### 4. Menu Bar App

- Lightweight, runs in background
- Simple UI to configure keyboard-to-input mappings
- Manual input switch buttons as fallback

## Technical Architecture

| Component            | Technology                  |
|---------------------|----------------------------|
| Language            | Swift                      |
| UI                  | SwiftUI + AppKit (menu bar)|
| Bluetooth monitoring| IOBluetooth framework      |
| DDC/CI commands     | IOKit (I2C) + m1ddc        |
| Persistence         | SwiftData + UserDefaults   |

## DDC/CI Input Source Codes

| Input       | DDC Code |
|-------------|----------|
| VGA-1       | 0x01     |
| DVI-1       | 0x03     |
| DisplayPort-1| 0x0F    |
| DisplayPort-2| 0x10    |
| HDMI-1      | 0x11     |
| HDMI-2      | 0x12     |
| USB-C       | 0x13     |

## Dependencies

- **m1ddc**: Required for DDC/CI communication on Apple Silicon Macs
  ```bash
  brew install m1ddc
  ```

## UI Design Notes

Settings page uses a skeuomorphic design:
1. Monitor section - shows detected display, click to detect if empty
2. Port section - select input port, double-click to switch, right-click to edit DDC ID
3. Keyboard section - select one Bluetooth keyboard

The visual layout itself represents the mapping (keyboard → port → monitor).

## Setup (per Mac)

1. Install BetterSwitch
2. Install m1ddc: `brew install m1ddc`
3. Select your Bluetooth keyboard from detected devices
4. Select which monitor input this Mac uses
5. Run on login

## Pre-development Info Needed

1. Monitor model (for DDC/CI compatibility)
2. Bluetooth keyboard model
3. Which input sources to support (e.g., HDMI1, HDMI2, USB-C)
