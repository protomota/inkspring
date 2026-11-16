# Inkspring logo assets

The editable mark is [public/inkspring-mark.svg](../public/inkspring-mark.svg). The macOS icon set and ICNS are included in the source checkout.

To regenerate them on macOS, install Google Chrome and run the following from the repository root.

```sh
npm install --prefix build
node build/generate-brand-assets.mjs
```

Intermediate assets are written to `.build/brand-assets`. Pass an output directory to use a different location. The script also generates website variants when a website checkout is present at `website/public`.
