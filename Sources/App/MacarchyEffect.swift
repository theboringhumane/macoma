import Foundation

struct MacarchyEffect: Identifiable {
    let id: String
    let name: String
    let family: String
    let detail: String
    let symbol: String

    static var all: [Self] {
        OmacyEffects.names.map { name in
            let metadata = descriptions[name]
            return Self(id: name, name: metadata?.0 ?? name.capitalized,
                        family: metadata?.1 ?? "Animation", detail: metadata?.2 ?? "Bring your artwork to life.",
                        symbol: metadata?.3 ?? "sparkles")
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static let descriptions: [String: (String, String, String, String)] = [
        "beams": ("Beams", "Light & color", "Rays of light sweep through your characters.", "light.beacon.max"),
        "binarypath": ("Binary Path", "Digital", "A trail of binary finds its way into your artwork.", "point.topleft.down.curvedto.point.bottomright.up"),
        "blackhole": ("Black Hole", "Particles", "Characters orbit a dark center before settling into place.", "circle.dotted.circle"),
        "bouncyballs": ("Bouncy Balls", "Particles", "A playful cascade of characters with a little bounce.", "circle.grid.2x2"),
        "bubbles": ("Bubbles", "Particles", "Floating bubbles carry your characters into view.", "bubbles.and.sparkles"),
        "burn": ("Burn", "Weather & flow", "A glowing ember effect moves across your artwork.", "flame"),
        "colorshift": ("Color Shift", "Light & color", "A rolling spectrum of color transforms the canvas.", "circle.lefthalf.filled"),
        "crumble": ("Crumble", "Motion", "Your artwork breaks apart and falls through the canvas.", "square.stack.3d.down.right"),
        "decrypt": ("Decrypt", "Digital", "Scrambled characters resolve into a familiar message.", "lock.open"),
        "errorcorrect": ("Error Correct", "Digital", "Watch a corrupted signal find the right characters.", "checkmark.shield"),
        "expand": ("Expand", "Motion", "Characters spread out from the center into your design.", "arrow.up.left.and.arrow.down.right"),
        "fireworks": ("Fireworks", "Particles", "Bursts of color light up the canvas, one character at a time.", "sparkles"),
        "highlight": ("Highlight", "Light & color", "A bright highlight travels across your finished artwork.", "highlighter"),
        "laseretch": ("Laser Etch", "Light & color", "A precise beam traces your artwork into the dark.", "line.diagonal.arrow"),
        "matrix": ("Matrix", "Digital", "A familiar rain of green characters reveals your artwork.", "text.line.first.and.arrowtriangle.forward"),
        "middleout": ("Middle Out", "Motion", "Your artwork unfolds from its center.", "arrow.left.and.right.righttriangle.left.righttriangle.right"),
        "orbittingvolley": ("Orbiting Volley", "Particles", "Characters sweep around the canvas in coordinated orbits.", "atom"),
        "overflow": ("Overflow", "Digital", "Rows of text fill the screen before finding their place.", "text.alignleft"),
        "pour": ("Pour", "Weather & flow", "Characters pour into the canvas and build your artwork.", "drop.fill"),
        "print": ("Print", "Digital", "A terminal-inspired reveal, printed character by character.", "printer"),
        "rain": ("Rain", "Weather & flow", "A gentle shower of characters falls into position.", "cloud.rain"),
        "randomsequence": ("Random Sequence", "Reveal", "Characters appear in an unpredictable, scattered sequence.", "shuffle"),
        "rings": ("Rings", "Motion", "Concentric rings set your characters in motion.", "circle.circle"),
        "scattered": ("Scattered", "Motion", "Loose characters move across the screen to form your artwork.", "square.grid.3x3"),
        "slice": ("Slice", "Motion", "Strips of your artwork slide together.", "rectangle.split.3x1"),
        "slide": ("Slide", "Motion", "Characters glide into place from the edges.", "arrow.right.to.line"),
        "smoke": ("Smoke", "Weather & flow", "Soft clouds of characters drift through the canvas.", "smoke"),
        "spotlights": ("Spotlights", "Light & color", "Moving pools of light search across your artwork.", "flashlight.on.fill"),
        "spray": ("Spray", "Reveal", "A spray of characters paints your design onto the screen.", "aqi.medium"),
        "swarm": ("Swarm", "Particles", "A restless cloud of characters gathers into your artwork.", "circle.hexagongrid"),
        "sweep": ("Sweep", "Reveal", "A moving sweep brings each part of the artwork into view.", "arrow.right"),
        "synthgrid": ("Synth Grid", "Light & color", "A retro grid sets the stage for your artwork.", "grid"),
        "thunderstorm": ("Thunderstorm", "Weather & flow", "Rain and flashes of light roll across the canvas.", "cloud.bolt.rain"),
        "unstable": ("Unstable", "Motion", "Characters shake loose before finding their balance.", "waveform.path"),
        "vhstape": ("VHS Tape", "Digital", "Analog tracking noise gives your artwork a nostalgic glitch.", "play.rectangle"),
        "waves": ("Waves", "Light & color", "Waves of color ripple through the characters.", "water.waves"),
        "wipe": ("Wipe", "Reveal", "A clean wipe reveals your artwork across the canvas.", "rectangle.leadinghalf.inset.filled")
    ]
}
