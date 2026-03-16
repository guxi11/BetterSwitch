
● BetterSwitch - Product Requirements Document

  Overview

  A macOS menu bar app that automatically switches monitor input source when a Bluetooth   keyboard connects.

  Problem

  When using one monitor with multiple Macs and a Bluetooth keyboard that can switch
  between devices, users must manually switch the monitor input every time they switch
  keyboards.

  Solution

  Detect Bluetooth keyboard connection events and automatically send DDC/CI commands to
  switch the monitor to the corresponding input source.

  Core Features

  1. Bluetooth Keyboard Detection

  - Monitor for specific Bluetooth keyboard connect/disconnect events
  - Identify keyboard by device name or Bluetooth ID

  2. DDC/CI Input Switching

  - Send DDC/CI commands to switch monitor input source
  - Support common inputs: HDMI1, HDMI2, DisplayPort, USB-C, etc.

  3. Configuration

  - Map keyboard connection → specific input source
  - Example: "When MX Keys connects → switch to HDMI1"

  4. Menu Bar App

  - Lightweight, runs in background
  - Simple UI to configure keyboard-to-input mappings
  - Manual input switch buttons as fallback

  Technical Requirements

  ┌──────────────────────┬─────────────────────────────┐
  │ Component            │ Technology                  │
  ├──────────────────────┼─────────────────────────────┤
  │ Language             │ Swift                       │
  ├──────────────────────┼─────────────────────────────┤
  │ UI                   │ SwiftUI + AppKit (menu bar) │
  ├──────────────────────┼─────────────────────────────┤
  │ Bluetooth monitoring │ IOBluetooth framework       │
  ├──────────────────────┼─────────────────────────────┤
  │ DDC/CI commands      │ IOKit (I2C)                 │
  ├──────────────────────┼─────────────────────────────┤
  │ Persistence          │ UserDefaults                │
  └──────────────────────┴─────────────────────────────┘

  Setup (per Mac)

  1. Install BetterSwitch
  2. Select your Bluetooth keyboard from detected devices
  3. Select which monitor input this Mac uses
  4. Run on login

  Info Needed Before Development

  1. Monitor model (for DDC/CI compatibility)
  2. Bluetooth keyboard model
  3. Which input sources to support (e.g., HDMI1, HDMI2, typec)
