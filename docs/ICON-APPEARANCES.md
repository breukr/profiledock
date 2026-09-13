# Icon appearances


The application retains the four-tile ProfileDock mark in monochrome. The layered `Resources/ProfileDock.icon` artwork defines light, dark and mono treatments; macOS derives tinted and clear renditions. **Auto** uses the bundled system-rendered icon. **Dark**, **Light**, **Tinted** and **Clear** override the running app's Dock icon. Finder remains governed by the system appearance. Clear and Tinted use light/dark variants according to the current macOS appearance.

`./scripts/render-icon-appearances.sh` regenerates the six previews using Apple's Icon Composer. `./scripts/build-app.sh` compiles the layered icon for distribution. Xcode 26 or newer provides the native icon compilation tool.

