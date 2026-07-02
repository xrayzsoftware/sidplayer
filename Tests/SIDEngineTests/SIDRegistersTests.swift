import XCTest
@testable import SIDEngine

final class SIDRegistersTests: XCTestCase {

    private func emptyImage() -> [UInt8] { [UInt8](repeating: 0, count: 32) }

    /// The control byte drives the waveform/gate badges; a wrong bit mapping
    /// would show the user the wrong oscillator shape.
    func testVoiceControlBitsDecode() {
        var img = emptyImage()
        img[0x04] = 0x41                 // voice 1: pulse + gate
        let v = SIDRegisters(image: img).voices[0]
        XCTAssertTrue(v.gate)
        XCTAssertTrue(v.pulse)
        XCTAssertFalse(v.triangle)
        XCTAssertFalse(v.sawtooth)
        XCTAssertFalse(v.noise)
        XCTAssertFalse(v.sync)
        XCTAssertFalse(v.ringMod)
        XCTAssertFalse(v.test)
    }

    /// Ring-mod / sync / test are the musically interesting flags; verify they
    /// decode independently of the waveform bits.
    func testModulationFlagsDecode() {
        var img = emptyImage()
        img[0x0B] = 0x16                 // voice 2 control: tri + ring + sync (0b0001_0110)
        let v = SIDRegisters(image: img).voices[1]
        XCTAssertTrue(v.triangle)
        XCTAssertTrue(v.ringMod)
        XCTAssertTrue(v.sync)
        XCTAssertFalse(v.gate)
        XCTAssertFalse(v.test)
    }

    /// Attack/decay (and sustain/release) share a byte as high/low nibbles.
    /// Swapping them would invert the envelope readout.
    func testADSRNibbleSplit() {
        var img = emptyImage()
        img[0x05] = 0x2A                 // attack 2, decay 10
        img[0x06] = 0xF9                 // sustain 15, release 9
        let v = SIDRegisters(image: img).voices[0]
        XCTAssertEqual(v.attack, 2)
        XCTAssertEqual(v.decay, 10)
        XCTAssertEqual(v.sustain, 15)
        XCTAssertEqual(v.release, 9)
    }

    /// Pulse width is 12-bit: low byte + low nibble of the high byte. The high
    /// nibble of the high byte must be ignored.
    func testPulseWidth12Bit() {
        var img = emptyImage()
        img[0x02] = 0x00
        img[0x03] = 0x18                 // only low nibble (0x8) is part of PW
        let v = SIDRegisters(image: img).voices[0]
        XCTAssertEqual(v.pulseWidth, 0x800)
        XCTAssertEqual(v.pulseWidthPercent, 50.01, accuracy: 0.1)
    }

    /// The point of the readout is naming the pitch you hear: 440 Hz must read
    /// as A4. freg = 440 · 2²⁴ / Fclk(PAL) ≈ 7493 (0x1D45).
    func testFrequencyDecodesToNoteA4_PAL() {
        var img = emptyImage()
        img[0x00] = 0x45
        img[0x01] = 0x1D
        let note = SIDRegisters(image: img).voices[0].note(clock: .pal)
        XCTAssertEqual(note?.name, "A")
        XCTAssertEqual(note?.octave, 4)
        XCTAssertEqual(note?.cents ?? 99, 0, accuracy: 5)
    }

    /// A silent oscillator (frequency 0) must not display a bogus note.
    func testSilentVoiceHasNoNote() {
        XCTAssertNil(SIDRegisters(image: emptyImage()).voices[0].note(clock: .pal))
    }

    /// NTSC's faster master clock must make the same register value sound
    /// higher — i.e. the clock has to flow through to the pitch, not be
    /// hardcoded to PAL.
    func testClockAffectsPitch() {
        var img = emptyImage()
        img[0x00] = 0x45
        img[0x01] = 0x1D
        let v = SIDRegisters(image: img).voices[0]
        XCTAssertGreaterThan(v.frequencyHz(clock: .ntsc), v.frequencyHz(clock: .pal))
    }

    func testFilterDecode() {
        var img = emptyImage()
        img[0x15] = 0x05                 // FC lo (low 3 bits)
        img[0x16] = 0xFF                 // FC hi
        img[0x17] = 0x71                 // resonance 7, route voice 1
        img[0x18] = 0x1F                 // volume 15, lowpass
        let r = SIDRegisters(image: img)
        XCTAssertEqual(r.cutoff, (0xFF << 3) | 0x05)   // 2045
        XCTAssertEqual(r.resonance, 7)
        XCTAssertTrue(r.filterVoice1)
        XCTAssertFalse(r.filterVoice2)
        XCTAssertEqual(r.volume, 15)
        XCTAssertTrue(r.lowpass)
        XCTAssertFalse(r.bandpass)
        XCTAssertFalse(r.highpass)
        XCTAssertFalse(r.voice3Off)
    }

    /// The decoder's documented contract: any image length is safe, missing
    /// bytes read as 0. `readRegisters` bridges from C++, so its buffer-size
    /// contract could silently change — this pins the no-crash behaviour.
    func testShortImageDecodesAsZeros() {
        for img in [[UInt8](), [UInt8](repeating: 0xFF, count: 10)] {
            let r = SIDRegisters(image: img)
            XCTAssertEqual(r.voices.count, 3)
            XCTAssertEqual(r.voices[2].frequency, 0, "bytes past the image read as 0")
            XCTAssertEqual(r.volume, 0)
        }
    }

    /// Each voice's registers live 7 bytes apart; a bad stride would attribute
    /// one voice's state to another.
    func testThreeVoiceOffsets() {
        var img = emptyImage()
        img[0x04] = 0x11                 // V1 triangle + gate
        img[0x0B] = 0x21                 // V2 sawtooth + gate
        img[0x12] = 0x81                 // V3 noise + gate
        let r = SIDRegisters(image: img)
        XCTAssertTrue(r.voices[0].triangle)
        XCTAssertTrue(r.voices[1].sawtooth)
        XCTAssertTrue(r.voices[2].noise)
        XCTAssertFalse(r.voices[0].sawtooth)
        XCTAssertFalse(r.voices[1].noise)
        XCTAssertFalse(r.voices[2].triangle)
    }
}
