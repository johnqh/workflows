# SVG Scripts

## PNG to SVG Vectorization

### vectorize_vtracer.py

Wrapper around [vtracer](https://github.com/nicholaschiasson/vtracer) (Rust bitmap tracer). Produces the best quality SVGs with stacked color layers and optimized polygon tracing. Requires `cargo install vtracer`.

Usage: `python3 vectorize_vtracer.py [input.png] [output.svg]`

Quality: PSNR ~20.6 dB, 75% within 20 RGB, 88% within 40 RGB.

### vectorize_quantized.py

Color quantization approach: k-means clusters the image into N colors, traces each color layer into SVG paths with compound holes. Smaller output than other methods.

Quality: PSNR ~16.0 dB, 76% within 20 RGB, 85% within 40 RGB.

### vectorize_logo.py

SLIC superpixel segmentation with iterative refinement. Edge-aware segmentation, LAB color merging, gradient fitting, dark outline detection, polygon splitting, and render-compare-adjust loop. Most complex pipeline.

Quality: PSNR ~16.5 dB, 64% within 20 RGB, 77% within 40 RGB.

## SVG Generation

### generate_logo_svg.py

Programmatic SVG generator for the Sudobility S-shaped grid logo. Outputs 13 gradient-colored rounded rectangles. Not a PNG converter.
