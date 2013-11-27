load 'music.rb'

bpm(120)
midi = LiveMIDI.new(bpm)
midi.program_change(0, 40)
bang do |b|
  midi.play(0, 60, 1) if b % 2 == 0
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

  #Play the music. 
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
end
