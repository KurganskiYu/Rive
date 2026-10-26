# Connect two external fonts to a Rive animation in the iOS app

The Rive file `78_cardpocket_v#.riv` has its fonts set to *Referenced*, so they are not embedded. The app has to supply them at load time through Rive's custom asset loader.

## What to do

1. Add the two font files to the app bundle (target membership on): `NovemberLC-Regular.otf` and `NovemberLC-Heavy.otf`.
2. When creating the `RiveFile`, pass a `customAssetLoader`. For each `RiveFontAsset`, match `asset.name` against the font file name without the extension (`NovemberLC-Regular`, `NovemberLC-Heavy`). Load the font bytes from the bundle, decode them with `factory.decodeFont(data)`, and call `asset.font(...)`. Return `true` for assets you handled and `false` for the rest.
3. Set `loadCdn: false`, since nothing is hosted on the Rive CDN.

## Sketch (Swift, adjust to the Rive iOS version in use)

```swift
let file = try RiveFile(name: "78_cardpocket_v#", extension: ".riv", loadCdn: false,
    customAssetLoader: { asset, _, factory in
        guard let fontAsset = asset as? RiveFontAsset,
              let url = Bundle.main.url(forResource: fontAsset.name, withExtension: "otf"),
              let data = try? Data(contentsOf: url) else { return false }
        fontAsset.font(factory.decodeFont(data))
        return true
    })
```

## Notes

- Asset names are exactly `NovemberLC-Regular` and `NovemberLC-Heavy`. They must match the bundled file names.
- The loader runs once per font asset when the file loads. Fonts need to be available before the `RiveViewModel` or view is created.
- Docs: [Rive runtime asset loading](https://rive.app/docs/runtimes/loading-assets) (Apple/iOS tab). Check the API names against the SDK version installed.
- A working web reference is in `pages/78_cardpocket_v#.html`, in the `assetLoader` function.
