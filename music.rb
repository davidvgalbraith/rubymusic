require 'dl'
require 'dl/import'

#Interface to the magic C-based land of music playing
class LiveMIDI
  ON = 0x90
  OFF = 0x80
  PC = 0xC0

  def initialize
    open
  end
  #start playing note # note on the instrument specified by
  #channel with velocity loudness (0-127 for not channel 0-16)
  def note_on(channel, note, velocity=64)
    message(ON | channel, note, velocity)
  end
  #stop playing note #note on the instrument specified by
  #channel with velocity meaningless
  def note_off(channel, note, velocity=64)
    message(OFF | channel, note, velocity)
  end
  #put instrument specified by preset on channel instead of current
  #instrument, there are more presets than channels (128 > 16)
  def program_change(channel, preset)
    message(PC | channel, preset)
  end
end

#customize for OS
if RUBY_PLATFORM.include?('mswin')
  class LiveMIDI
    module C
      extend DL::Importer
      dlload 'winmm'
      
      extern "int midiOutOpen(HMIDIOUT*, int, int, int, int)"
      extern "int midiOutClose(int)"
      extern "int midiOutShortMsg(int, int)"

    end
    def open
      @device = DL.malloc(DL.sizeof('I'))
      C.midiOutOpen(@device, -1, 0, 0, 0)
    end

    def close
      C.midiOutClose(@device.ptr.to_i)
    end

    def message(one, two=0, three=0)
      message = one + (two << 8) + (three << 16)
      C.midiOutShortMsg(@device.ptr.to_i, message)
    end
  end

#Nobody uses Macs; it's not a thing.
elsif RUBY_PLATFORM.include?('darwin')
  puts "Out of luck, ya Mac snorter."
  class LiveMIDI
    # Mac code here
  end


elsif RUBY_PLATFORM.include?('linux')
  class LiveMIDI
    module C
      #DL: "Dynamic Link" lets you run C in Ruby
      extend DL::Importer
      dlload 'libasound.so.2'
      extern "int snd_rawmidi_open(void*, void*, char*, int)"

      extern "int snd_rawmidi_close(void*)"

      extern "int snd_rawmidi_write(void*, void*, int)"
      
      extern "int snd_rawmidi_drain(void*)"
      
    end
    #open a connection to MIDI
    def open
      @output = DL::CPtr.new(0)
      C.snd_rawmidi_open(nil, @output.ref, "virtual", 0)
    end

    #close a connection to MIDI
    def close
      C.snd_rawmidi_close(@output)
    end
    
    #Send a MIDI message in the form of one "Status" byte and up
    #to two data bytes
    def message(*args)
      format = "C" * args.size
      bytes = DL::CPtr.to_ptr(args.pack(format))
      C.snd_rawmidi_write(@output, bytes, args.size)
      C.snd_rawmidi_drain(@output)
    end
  end
  
else
  raise "Couldn't find a LiveMIDI implementation for your platform"
end

#Do actions at regular intervals
class Timer
  #resolution gives the interval
  def initialize(resolution)
    @resolution = resolution
    @queue = []
    Thread.new do
      while true
        dispatch
        sleep(@resolution)
      end
    end
  end
  private
  def dispatch
    now = Time.now.to_f
    ready, @queue = @queue.partition{|time, proc| time <= now}
    ready.each {|time, proc| proc.call(time) }
  end
  
  public
  def at(time, &block)
    time = time.to_f if time.kind_of?(Time)
    @queue.push [time, block]
  end
  #For to support several timers with varying intervals
  #returns a timer with the specified interval
  def self.get(interval)
    @timers ||= {}
    return @timers[interval] if @timers[interval]
    return @timers[interval] = self.new(interval)
  end
end

#plays a note at regular intervals using a Timer
class Metronome
  def initialize(bpm)
    @midi = LiveMIDI.new
    @midi.program_change(0, 115)
    @interval = 60.0 / bpm
    @timer = Timer.get(@interval / 10.0)
    now = Time.now.to_f
    register_next_bang(now)
  end
  
  def register_next_bang(time)
    @timer.at(time) do
      now = Time.now.to_f
      register_next_bang(now + @interval)
      bang
    end
  end
  def bang
    @midi.play(0, 84, 0.1, Time.now.to_f + 0.2)
  end
end

class LiveMIDI
  attr_reader :interval
  #Add in a timer for to control note duration
  def initialize(bpm = 120)
    @interval = 60.0/bpm
    @timer = Timer.get(@interval/10)
    open
  end
  #put the note on now, take it off after duration
  def play(channel, note, duration, velocity = 100, time = nil)
    on_time = time || Time.now.to_f
    @timer.at(on_time) {note_on(channel, note, velocity)}
    off_time = on_time + duration
    @timer.at(off_time) {note_off(channel, note, velocity)}
  end
end
# - means play a pause, numbers indicate notes above/below given base note
class Pattern
  def parse(string) 
    characters = string.split(//)
    no_spaces = characters.grep(/\S/)
    return build(no_spaces)
  end
  def build(list) 
    return [] if list.empty?
    duration = 1 + run_length(list.rest)
    value = case list.first
            when /-|=/ then nil
            when /\D/ then 0
            else list.first.to_i
            end
    return [[value, duration]] + build(list.rest)
  end
  def initialize(base, string)
    @base = base
    @seq = parse(string)
  end
  def [](index) 
    value, duration = @seq[index % @seq.size]
    return value, duration if value.nil?
    return @base + value, duration
  end
  def size
    return @seq.size
  end
  #calculate duration for to play the note
  def run_length(list)
    return 0 if list.empty?
    return 0 if list.first != "="
    return 1 + run_length(list.rest)
  end
  
end

#cdr
module Enumerable
  def rest
    [] if empty?
    self[1..-1]
  end
end

#Exactly what it says on the tin
class SongPlayer

  def initialize(player, bpm, pattern) 
    @boo = true
    @player = player
    @interval = 60.0 / bpm
    @timer = Timer.get(@interval / 10.0)
    @count = 0
    @pattern = Pattern.new(60, pattern)
    play(Time.now.to_f)
  end
  #play the pattern at time time
  def play(time)
    if @boo
      @boo = false
      sleep(10)
    end
    note, duration = @pattern[@count]
    @count += 1
    return if @count > @pattern.size
    length = @interval * duration - (@interval * 0.10)
    @player.play(0, note, length) unless note.nil?
    @timer.at(time + @interval) {|at| play(at)}
  end
end

def marylamb
  bpm = 60
  midi = LiveMIDI.new(bpm)
  SongPlayer.new(midi, bpm, "4202 444= 222= 477=")
  sleep(10)
  puts "Done"
end

#plays a note from the pattern every time you hit enter
class Tapper
  def initialize(player, length, base, pattern)
    @player = player
    @length = length
    @pattern = Pattern.new(base, pattern)
    @count = 0
  end
  def run 
    while true
      print ":)"
      STDIN.gets
      note, duration = @pattern[@count]
      @count += 1
      @player.play(0, note, @length * duration) if note
    end
  end
end

def marytap
  bpm = 60
  midi = LiveMIDI.new(bpm)
  midi.program_change(0, 16)
  t = Tapper.new(midi, 0.5, 60, "4202 444= 222= 477=")
  t.run
end

marytap
