
bpm(120)
midi = LiveMIDI.new(bpm)
midi.program_change(0, 40)
bang do |b|
  midi.play(0, 60, 1) if b % 2 == 0
end
