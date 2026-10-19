# Snap Takeoff

Photograph a room or space. AI breaks it down into the things you'd buy and the work you'd pay for, then gives a rough cost to build it, adjusted for the city you pick.

**Live site:** https://ralphgeb.github.io/FridgeCheck/

## How it works

- Take or upload a photo. Claude (`claude-opus-5-5`) lists finishes, built-ins, fixtures, appliances and furniture with quantities, per-unit prices (US national average) and install hours.
- The page prices everything with city cost indexes for materials and labor, a finish level (Budget / As seen / Premium), contractor overhead & profit (15%) and contingency (10%).
- Untick items or change quantities; the total, cost per sq ft and city comparison update instantly.

## AI access

On GitHub Pages the photo is sent from your browser directly to the Anthropic API using your own API key (saved only in your browser's local storage). Opened inside Claude as an artifact, it uses your Claude account instead and needs no key.

City indexes are approximate and for planning only, not a bid.

It's a single static file (`index.html`) with no build step.
