Roboto Regular and Roboto Bold, copied from the OpenTX 2.3 source tree
(github.com/opentx/opentx, radio/src/fonts/Roboto/), where OpenTX builds its colour-screen fonts
from them (radio/src/fonts/480x272/CMakeLists.txt: Regular 9/13/16/24 px, Bold 32/64 px).

Roboto is licensed under the Apache License, Version 2.0 (https://www.apache.org/licenses/LICENSE-2.0).

Used only by tools/sim_edgetx.py --otx, to draw text the way an OpenTX radio does. The glyph widths
themselves are in edgetx/WIDGETS/OmniDeck/etx.lua (W_TIN ... W_XXL, from OpenTX's font_*.specs).
Nothing here is copied to the radio.
