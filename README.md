# SwipeKeys

A tiny macOS app that maps `WASD`, arrow keys, and Space to mouse gestures.

I made this to play Subway Surfers City on my MacBook after enjoying the game a
bit too much.

Made by [Guilherme Drezza](https://guidrezza.com).

## Controls

| Key | Action |
| --- | --- |
| `W` or Up Arrow | Swipe up |
| `S` or Down Arrow | Swipe down |
| `A` or Left Arrow | Swipe left |
| `D` or Right Arrow | Swipe right |
| Space | Tap |
| `Command` + `Control` + `Option` + `K` | Toggle on/off |

Actions happen around the cursor. Original key presses still pass through.

## Install

Download `SwipeKeys-macOS.zip` from the latest GitHub release, unzip it, and
drag `SwipeKeys.app` into Applications.

SwipeKeys needs:

- Accessibility
- Input Monitoring

Open SwipeKeys, click the permission buttons, enable both in System Settings,
then reopen the app if macOS asks.

## Build

```sh
git clone https://github.com/guidrezza/SwipeKeys.git
cd SwipeKeys
./Scripts/build-app.sh
```

The app is created at `dist/SwipeKeys.app`.

## License

MIT. See [LICENSE](LICENSE).
