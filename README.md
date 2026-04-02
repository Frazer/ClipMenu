ClipMenu
========
A clipboard manager for Mac OS X.

**New ClipMenu, completely rebuilt using Swift language, is now under development. Further information is coming soon!**

![ClipMenu](./screenshot.jpg)

## Distribution

If you distribute derived work, especially in the Mac App Store, I ask you to follow two rules:

1. **Don't use "ClipMenu" as your product name.**
2. **Follow the MIT license terms.**

Thank you for your cooperation.

Target environments
-------------------

* macOS 11.0 or later (Apple Silicon + Intel)
* Xcode 15+ recommended
* Manual reference counting

Apple Silicon notes
-------------------

* The Xcode project now uses `$(ARCHS_STANDARD)` with `SDKROOT = macosx`, so arm64 is built natively on Apple Silicon.
* `MACOSX_DEPLOYMENT_TARGET` is set to `11.0` to align with Apple Silicon availability.
* There is no public compiler flag to tune specifically for an "M5" CPU generation. Building as arm64 with modern Xcode/Clang already enables Apple Silicon-native code generation and optimization.

Dependencies
------------
The source code is dependent on some libraries. You have to download and install them if you want to compile, run, or test the source code.

* [PTHotKey](http://www.rogueamoeba.com/utm/posts/Random/Homegrown_Developer_Tools-2004-07-14-12-00) by Quentin D. Carnicelli
* [Shortcut Recorder](http://code.google.com/p/shortcutrecorder/) by contributors to ShortcutRecorder
* [Sparkle](http://sparkle.andymatuschak.org/) by Andy Matuschak
* [DBPrefsWindowController](http://www.mere-mortal-software.com/blog/sourcecode.php) by Dave Batton
* [Google Toolbox for Mac](http://code.google.com/p/google-toolbox-for-mac/) by Google Inc.
* [BWToolkit](http://www.brandonwalkin.com/bwtoolkit/) by Brandon Walkin

Author
------

Naotaka Morimoto ([@naotakaM](http://twitter.com/naotakaM))

License
-------
ClipMenu is available under the MIT license. See the LICENSE file for more info.

Icons are copyrighted by their respective authors.
