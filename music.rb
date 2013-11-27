require 'dl'
require 'dl/import'
require 'midilib'
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
      #sleep(10)
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


#class for storing music I write lol
class FileMIDI
  attr_reader :interval
  
  #sequences have tracks, tracks have events, events are note on/off etc.
  def initialize(bpm) 
    @bpm = bpm
    @interval = 60.0/bpm
    @base = Time.now.to_f
    @seq = MIDI::Sequence.new
    header_track = MIDI::Track.new(@seq)
    @seq.tracks << header_track
    header_track.events << MIDI::Tempo.new(MIDI::Tempo.bpm_to_mpq(@bpm))
    @tracks = []
    @last = []
  end
  
  #Get a track for channel (each channel is an instrument)
  def new_track(channel)
    track = MIDI::Track.new(@seq)
    @tracks[channel] = track
    @seq.tracks << track
    return track
  end
  
  #Redefine channel as the instrument at preset
  def program_change(channel, preset)
    track = new_track(channel)
    track.events << MIDI::ProgramChange.new(0, preset, 0)
  end
  
  #Get the track of channel
  def channel_track(channel)
    @tracks[channel] || new_track(channel)
  end
  
  #Play note on channel for duration with velocity at time
  def play(channel, note, duration=1, velocity=100, time=nil) 
    time ||= Time.now.to_f
    on_delta = time - (@last[channel] || time)
    off_delta = duration * @interval
    @last[channel] = time
    track = channel_track(channel)
    track.events << MIDI::NoteOnEvent.new(0, note, velocity, seconds_to_delta(on_delta))
    track.events << MIDI::NoteOffEvent.new(0, note, velocity, seconds_to_delta(off_delta))
  end

  #magic MIDI conversion nonsense
  def seconds_to_delta(secs) 
    bps = 60.0 / @bpm
    beats = secs / bps
    return @seq.length_to_delta(beats)
  end

  #write to file
  def save(output_filename)
    File.open(output_filename, 'wb') do |file|
      @seq.write(file)
    end
  end
end

def marysave
  bpm = 120
  midi = FileMIDI.new(bpm)
  SongPlayer.new(midi, bpm, "4202 444= 222= 477=")
  sleep(10)
  midi.save("mary.mid")
end 


#Class for live-coding music
class Player
  attr_reader :tick
  
  def initialize
    bpm(120)
    reset
  end

  #callbacks are bangs that play music, closebacks turn it off/on
  def reset
    @callbacks = []
    @closebacks = []
  end
  
  def bpm(beats_per_minute = nil) 
    unless beats_per_minute.nil?
      @bpm = beats_per_minute
      @tick = 60.0/@bpm
    end
    return @bpm
  end

  def bang(callback1 = nil, &callback2)
    @callbacks.push(callback1) if callback1
    @callbacks.push(callback2) if callback2
  end

  def close(closeback1 = nil, &closeback2) 
    @closebacks.push(closeback1) if closeback1
    @closebacks.push(closeback2) if closeback2
  end
  
  #Run all the callbacks (definition of bang).
  def on_bang(b)
    @callbacks.each {|callback| callback.call(b)}
  end
 
  #Run all the closebacks(Definition of close)
  def on_close
    @closebacks.each {|closeback| closeback.call}
  end
end

#Given a file, check the file for changes and play the new music written to file live
class Monitor
  def initialize(filename)
    raise "File does not exist" if ! File.exists?(filename)
    raise "Can't read file" if ! File.readable?(filename)
    #Check file for updates twice every second
    @timer = Timer.get(0.5)
    @filename = filename
    @bangs = 0
    @players = [Player.new()]
    load
  end
  #read in music, prepare to drop
  def load()
    code = File.open(@filename) {|file| file.read}
    dup = @players.last.dup
    begin
      dup.reset
      dup.instance_eval(code)
      @players.push(dup)
    rescue
      puts "LOAD ERROR #{$!}"
    end
    @load_time = Time.now.to_i
  end

  #Find out if the file has been modified
  def modified?
    return File.mtime(@filename).to_i > @load_time
  end

  #Play the music, now is when it starts
  def run(now=nil)
    now ||= Time.now.to_f
    load() if modified?
    begin
      @players.last.on_bang(@bangs)
    rescue
      puts "RUN ERROR: #{$!}"
      @players.pop
      retry unless @players.empty?
    end
    @bangs += 1
    @timer.at(now + @players.last.tick) {|time| run(time)}
  end
  
  #Don't let it stop
  def run_forever
    run
    sleep(10) while true
  end
end
