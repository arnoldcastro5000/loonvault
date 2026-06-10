# LoonVault

A security proof-of-concept and portfolio project, built to demonstrate bank-grade cloud security for a financial-services cloud-security specialist role. The data is payload, not the point: a public API serving Bank of Canada economic data gives the project real infrastructure worth securing. All engineering effort is directed at the security story — defense-in-depth architecture, a STRIDE threat model mapped to OSFI B-13 / E-23, and live attack-and-defense demonstrations. The backend is ephemeral (`terraform apply` before interviews, `terraform destroy` after); the frontend — a static site on S3 served through the Cloudflare proxy — is always-on.

## Language

### Data

**Series**:
A named time series of economic data fetched directly from the Bank of Canada Valet API (e.g., CPI, M2 money supply, CAD/USD exchange rate, Overnight Rate, BCPI, 10-year GoC bond yield). A Series is the atomic unit of source data in LoonVault.
_Avoid_: indicator (when referring specifically to raw fetched data), metric, data point

**Pressure Metric**:
A value computed from one or more stored Series that indicates economic stress. Not fetched from BoC Valet — derived internally. The three named Pressure Metrics in LoonVault are:
- **Real M2** — M2 money supply ÷ CPI index. Removes inflation distortion from money supply; contraction signals reduced liquidity.
- **Yield Curve Spread** — 10-year GoC bond yield minus 2-year GoC bond yield. Inversion (negative value) is a historically reliable recession signal.
- **Bank Credit Growth Rate** — month-over-month percentage change in bank credit. Deceleration signals tightening lending conditions.
_Avoid_: derived series, computed indicator, derived metric

**Indicator**:
The umbrella term for anything the public API exposes — encompasses both Series and Pressure Metrics. Used in all external-facing descriptions ("cost-of-living indicators").
_Avoid_: metric (too narrow), series (too narrow when referring to the full API surface)
