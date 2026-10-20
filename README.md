# Plume Avios Wallet

A household Avios and BA Club app for points nerds. Live at https://ralphgeb.github.io/FridgeCheck/

- **Wallet**: everyone's Avios, Tier Points progress, vouchers with expiry countdowns, Avios expiry warnings and "best use right now" ideas.
- **Redeem**: sweet spots ranked by pence per Avios, a reward calendar (peak/off-peak pricing per day, best dates, seat data imported from BA calendar screenshots or tapped in), every destination you can reach, and an upgrade calculator.
- **Earn**: goal planner, card optimiser (net £ value a year per card including Companion/Upgrade vouchers and fees), "should I buy Avios?" check, expiry watch and ways to earn.
- **Trips**: boarding-pass log with distance flown and Avios earned and spent.
- **Settings**: accounts (fill them from BA screenshots), vouchers (import from screenshots), Household pooling, Anthropic API key for smart import, backup and restore.

## Smart import

Screenshots are read by Claude through the Anthropic API using the user's own key, sent straight from the browser. Nothing goes to any other server.

## What it can't do

British Airways has no public API, so Plume can't sign in to BA accounts or fetch live reward availability. Seat data comes from screenshots the user imports. Reward prices, peak dates, cash fares and card rates are indicative. Not affiliated with British Airways or Avios.

Static site: `index.html`, `icon.svg`, PNG icons and `manifest.webmanifest`. No build step.
