# SwipeKeys

SwipeKeys is a tiny open-source macOS helper that turns `WASD` and arrow keys
into trackpad-like swipe events, and Space into a tap, while a matching app is
frontmost.

It was made for trackpad-only iPhone-on-Mac games, but it is generic: by default
it activates for apps whose name or bundle identifier contains `subway`.

## Why

Some iPhone games on macOS accept trackpad swipes and taps but do not expose
keyboard controls. SwipeKeys listens for a small set of keys and posts
synthetic input events that many of those apps interpret as touch gestures.

The original key events still pass through normally. `WASD`, arrow keys, and
Space are not blocked.

## Controls

| Key | Swipe |
| --- | --- |
| `W` or Up Arrow | Up |
| `S` or Down Arrow | Down |
| `A` or Left Arrow | Left |
| `D` or Right Arrow | Right |
| Space | Tap the center of the frontmost game window |

## Install

You need Xcode command line tools or Xcode installed.

```sh
git clone https://github.com/guidrezza/SwipeKeys.git
cd SwipeKeys
swift build -c release
```

Run it:

```sh
.build/release/swipekeys
```

The first run will ask for Accessibility permission. Enable SwipeKeys in
System Settings, then run it again.

## Options

```sh
swipekeys --match subway
swipekeys --match "Subway Surfers"
swipekeys --intensity 24 --repeats 6
swipekeys --verbose
```

`--match` checks the frontmost app's visible name and bundle identifier. Keeping
the match narrow prevents SwipeKeys from consuming keys in other apps.

## Development

```sh
swift build
swift run swipekeys --help
```

## Publishing

From this folder, create the public GitHub repository and push it with:

```sh
gh repo create SwipeKeys --public --source=. --remote=origin --push
```

If `gh` is not installed yet:

```sh
brew install gh
gh auth login
```

## License

MIT
