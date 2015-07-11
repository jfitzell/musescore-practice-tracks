require 'zip'
require 'nokogiri'
require 'pathname'
require 'tempfile'

SOUNDFONT = '/Users/julian/Documents/MuseScore2/Soundfonts/acoustic_grand_piano_ydp_20080910.sf2'

class Part
	def self.create_all(xml)
		return xml.xpath('//Score/Part').collect { |el| Part.new(el) }
	end

	def initialize(element)
		@element = element
	end
	
	def channel
		return @element.at_xpath('Instrument/Channel')
	end
	
	def muted?
		mute = channel.at_xpath('mute')
		return ! (mute.nil? || (mute.content == '0'))
	end
	
	def mute!
		mute = channel.at_xpath('mute')
		if (mute.nil?)
			mute = @element.document.create_element('mute')
			channel << mute
		end
		mute.content = '1'
		
		return self
	end
	
	def unmute!
		mute = channel.at_xpath('mute')
		unless (mute.nil?)
			mute.remove
		end
		
		return self
	end
		
	def solo?
		solo = channel.at_xpath('solo')
		return ! (solo.nil? || (solo.content == '0'))
	end
	
	def solo!
		solo = channel.at_xpath('solo')
		if (solo.nil?)
			solo = @element.document.create_element('solo')
			channel << solo
		end
		solo.content = '1'
		
		return self
	end
	
	def unsolo!
		solo = channel.at_xpath('solo')
		unless (solo.nil?)
			solo.remove
		end
		
		return self
	end
	
	def volume
		volume = channel.at_xpath('controller[@ctrl=7]')
		return volume.nil? ? 100 : volume['value'].to_i
	end
	
	def volume=(value)
		raise 'Invalid volume' if (value < 0 || value > 127)
		
		volume = channel.at_xpath('controller[@ctrl=7]')
		if (volume.nil?)
			volume = @element.document.create_element('controller')
			volume['ctrl'] = '7'
			channel << volume
		end
		volume['value'] = value.to_i.to_s
	end
		
	def pan
		pan = channel.at_xpath('controller[@ctrl=10]')
		panInt = pan.nil? ? 64 : pan['value'].to_i
		return [-1.0, (panInt.to_f - 64) / 63].max
	end
	
	def pan=(value)
		raise 'Invalid pan' if (value < -1 || value > 1)
		
		pan = channel.at_xpath('controller[@ctrl=10]')
		if (pan.nil?)
			pan = @element.document.create_element('controller')
			pan['ctrl'] = '10'
			channel << pan
		end
		pan['value'] = ((value.to_f * 63) + 64).floor.to_s
	end
	
	def vocal?
		instrument = @element.at_xpath('Instrument/instrumentId')
		
		return instrument.nil? ? false : instrument.content =~ /^voice\./
	end
	
	def empty?
		staff_ids = @element.xpath('Staff').collect { |el| el['id'] }
		staves = @element.parent.xpath('Staff').select { |el| staff_ids.include? el['id'] }
		
		return staves.all? { |staff| staff.at_xpath('.//Note').nil? }
	end
	
	def name
		@element.at_xpath('trackName').content
	end
end

def convert(scorePath, mp3Path, tags={})
	midiPath = mp3Path.sub_ext('.mid')
	puts "Converting score to MIDI: #{midiPath}"
	system "'/Applications/MuseScore 2.app/Contents/MacOS/mscore' '#{scorePath}' -o '#{midiPath}' 2> /dev/null"

	puts "Converting MIDI to MP3: #{mp3Path}"
	tagOptions = []
	tagOptions << "--tg '#{tags[:genre]}'" if tags.has_key? :genre
	tagOptions << "--tl '#{tags[:album]}'" if tags.has_key? :album
	tagOptions << "--ta '#{tags[:artist]}'" if tags.has_key? :artist
	tagOptions << "--tt '#{tags[:title]}'" if tags.has_key? :title
 	system "timidity -EI0 '#{midiPath}' -x'soundfont #{SOUNDFONT}' -A300 -Ow -o - 2> /dev/null | lame #{tagOptions.join(' ')} - '#{mp3Path}'"
	puts "Cleaning up..."
	midiPath.delete
# 	IO.copy_stream(scorePath, mp3Path.sub_ext('.mscz'))
end

def create_modified_track(sourceFile, outputFile)
	Tempfile.open [File.basename(sourceFile), File.extname(sourceFile)] do |temp|
		IO.copy_stream(sourceFile, temp)
		
		tags = {:genre => 'Chorus', :artist => 'News Choir'}
		Zip::File.open(temp) do |zip|
			source = zip.glob('*.mscx').first
			doc = source.get_input_stream { |io| Nokogiri::XML(io) }

			yield doc, tags
			
			zip.get_output_stream(source.name) do |io|
				doc.write_to(io)
			end
			zip.commit
		end
		
# 		puts temp.path
# 		sleep 20
		convert(temp.path, outputFile, tags)
	end
end

# should be a method of a class called Score
def get_title(doc, default)
	titleTag = doc.at_xpath('//Score/metaTag[@name="workTitle"]')
	return (titleTag && !titleTag.content.empty?) ?
		titleTag.content :
		default
end

def create_solo_track(partIndex, sourceFile, outputFile)
	 create_modified_track(sourceFile, outputFile) do |doc, tags|
		parts = Part.create_all(doc)
		solo = parts[partIndex]
		vocals = parts.select { |p| p != solo && p.vocal? }
		others = parts - vocals - [solo]
		
		# BUG: Solo doesn't apply during to export
		#  https://musescore.org/en/node/21854
		
		title = get_title(doc, File.basename(sourceFile, '.mscz'))
		tags[:album] = "Practice: #{title}"
		tags[:title] = "#{solo.name} (Solo) - #{title}"
		
# 		puts "Muting all except #{solo.name}..."
		parts.each { |p| p.mute!.unsolo!.volume = 0 }
# 		puts "Soloing #{solo.name}..."
		solo.solo!.unmute!.pan=0
		solo.volume=110
	end
end

def create_dominant_track(partIndex, sourceFile, outputFile)
	 create_modified_track(sourceFile, outputFile) do |doc, tags|
		parts = Part.create_all(doc)
		dominant = parts[partIndex]
		vocals = parts.select { |p| p != dominant && p.vocal? }
		others = parts - vocals - [dominant]
		
		title = get_title(doc, File.basename(sourceFile, '.mscz'))
		tags[:album] = "Practice: #{title}"
		tags[:title] = "#{dominant.name} (Dominant) - #{title}"
		
		parts.each { |p| p.unsolo! }
		vocals.each do |p|
			p.pan = -1
# 			p.volume = 0.5 * p.volume
			p.volume = 50
		end
		others.each do |p|
			p.pan = -1
# 			p.volume = 0.5 * p.volume
			p.volume = 40
		end
		dominant.unmute!.pan=1
		dominant.volume = 110
	end
end

# compressedFile = Pathname.new('/Users/julian/Documents/MuseScore2/Scores/Bobby Shaftoe.mscz')

Pathname.glob('/Users/julian/Documents/MuseScore2/Scores/*.mscz') do |compressedFile|
	Zip::File.open(compressedFile) do |zip|
		source = zip.glob('*.mscx').first
		doc = source.get_input_stream { |io| Nokogiri::XML(io) }
	
		parts = Part.create_all(doc)
	
		vocals = parts.each_index.select { |i| parts[i].vocal? && not(parts[i].empty?) }
		vocals.each do |i|
			create_solo_track(i, compressedFile, compressedFile.sub_ext("-#{parts[i].name.gsub(/[^ \w]/, '_')}-solo.mp3"))
			create_dominant_track(i, compressedFile, compressedFile.sub_ext("-#{parts[i].name.gsub(/[^ \w]/, '_')}-dominant.mp3"))
		end
	
		title = get_title(doc, File.basename(compressedFile, '.mscz'))
		convert(compressedFile, compressedFile.sub_ext('.mp3'),
			{:artist => 'News Choir', :genre => 'Chorus',
			:album => "Practice: #{title}", :title => title})
	end
end
