# Haven Design Tokens Reference

Source: `HavenEngineering/module-shared-haven-ui` (GitHub)

## Colors (from src/tokens/colors.json)

### Brand
| Token | Value | Usage |
|-------|-------|-------|
| haven-100 | #ebf8ff | Hover bg, faint tint |
| haven-200 | #e1f4ff | Light accent bg |
| haven-300 | #c0e8ff | Border accent |
| haven-400 | #007cc2 | "Haven blue" (legacy) |
| haven-500 | #0076b8 | **Primary** — buttons, links, focus rings |
| haven-600 | #006299 | Primary hover |
| haven-700 | #005180 | Primary active/pressed |

### Midnight (dark blues)
| Token | Value | Usage |
|-------|-------|-------|
| midnight-400 | #1d3e73 | Header nav bg, dark accents |
| midnight-500 | #193562 | Table headers |
| midnight-700 | #10223f | Darkest blue |

### Pebble (neutrals)
| Token | Value | Usage |
|-------|-------|-------|
| pebble-100 | #faf9f7 | Page bg, alt row |
| pebble-200 | #f2f1f0 | Light border, skip badge bg |
| pebble-300 | #d9d8d7 | **Default border** |
| pebble-400 | #bfbfbd | Disabled, placeholder |
| pebble-500 | #8c8c8b | Muted text |
| pebble-600 | #666665 | Secondary text |
| pebble-700 | #4c4c4c | Input borders (per design system) |

### Signal Colors
| Token | Value | Usage |
|-------|-------|-------|
| signalRed-400 | #d13130 | Error text/icon |
| signalRed-100 | #fff2f2 | Error bg |
| signalRed-300 | #ffbfbf | Error border |
| signalGreen-400 | #248254 | Success text/icon |
| signalGreen-100 | #f2fff9 | Success bg |
| signalGreen-300 | #a7f0cc | Success border |

### Legacy Dark Blue (body text)
| Token | Value | Usage |
|-------|-------|-------|
| darkBlue-100 | #031545 | **Body text color** |
| darkBlue-75 | #424f73 | Secondary text alt |

## Typography (from src/style/_variables.scss)
- **Font**: `"Open Sans"` variable font (woff2 from `haven.com/assets/fonts/OpenSans-Variable.woff2`)
- **Fallbacks**: -apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Oxygen-Sans, Ubuntu, Cantarell, Helvetica Neue, sans-serif
- **Body size**: 16px, line-height 1.75
- **Weights**: 425 (normal), 650 (bold), 775 (black)

## Spacing
- **Base grid**: 8px (`$spacingBase`)
- **Grid function**: `grid(n)` = n * 8px
- **Container**: 1330px max-width, 30px gap, 12 columns

## Radii
- **Card**: 4px (`$cardRadius`)
- **Input**: `grid(2)` = 16px
- **Input height**: `grid(10)` = 80px (but 40px is used in many components)

## Breakpoints
| Name | Width |
|------|-------|
| xs | 0 |
| sm | 500px |
| md | 800px |
| lg | 1100px |
| xl | 1400px |

## Input States
- Default border: `pebble-700` (#4c4c4c)
- Hover border: same
- Focus border: `haven-500` (#0076b8)
- Error: `signalRed-400`
- Disabled text: pebble-600 (#666665)

## GitHub
- Repo: `HavenEngineering/module-shared-haven-ui`
- Storybook: https://havenengineering.github.io/module-shared-haven-ui
- NPM: `@havenengineering/module-shared-library`
