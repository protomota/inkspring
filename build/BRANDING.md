# Inkspring logo assets

The editable mark is `public/inkspring-mark.svg`. It contains three separate ink-drop paths and a true circle: center (2508, 1388), radius 145 in the original flipped coordinate system. Do not convert the dot back to the old irregular traced path.

Keep the native icons and the website mark consistent with the master. The website has its own copy at `website/public/inkspring-mark.svg` because it deploys independently.

Install the rendering dependency with `npm install --prefix build`, then run `node build/generate-brand-assets.mjs` from the desktop repository to regenerate the macOS icon set/ICNS and the website's PNG logo variants, social image and Apple touch icon. Rendering takes place on Expand; the small shipped source assets are copied into their repositories. It uses Playwright and headless Chrome. Existing colors, transparency and asset layouts are retained; even the taller legacy layouts keep a circular dot.

These updates are local. Existing installed app bundles and deployed website assets remain unchanged until a new build is installed or a separately approved deployment is made.
