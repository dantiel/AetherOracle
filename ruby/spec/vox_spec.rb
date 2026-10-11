# frozen_string_literal: true

require 'spec_helper'
require_relative '../instrumentarium/vox'

RSpec.describe Vox do
  describe '.voices' do
    it 'parses voice lines into name/locale/language hashes' do
      sample = <<~OUT
        Anna                de_DE    # Hallo!
        Daniel              en_GB    # Hello!
        Eddy (Deutsch (Deutschland)) de_DE    # Hallo!
        Majed               ar_001   # Hello!
      OUT

      allow(Open3).to receive(:capture3).and_return([sample, '', double(success?: true)])
      voices = Vox.voices

      expect(voices.map { |v| v[:name] }).to include('Anna', 'Daniel', 'Eddy (Deutsch (Deutschland))', 'Majed')
      anna = voices.find { |v| v[:name] == 'Anna' }
      expect(anna[:locale]).to eq('de_DE')
      expect(anna[:language]).to eq('de')
    end

    it 'sorts German voices first' do
      sample = "Daniel              en_GB    # Hi\nAnna                de_DE    # Hallo\n"
      allow(Open3).to receive(:capture3).and_return([sample, '', double(success?: true)])

      expect(Vox.voices.first[:name]).to eq('Anna')
    end

    it 'returns [] when say is unavailable' do
      allow(Open3).to receive(:capture3).and_return(['', 'err', double(success?: false)])
      expect(Vox.voices).to eq([])
    end
  end

  describe '.speak' do
    it 'rejects empty text' do
      expect(Vox.speak(text: '   ')).to be(false)
    end

    it 'launches say with the voice and feeds text via stdin' do
      reader = double('reader', close: nil)
      writer = double('writer')
      allow(writer).to receive(:write)
      allow(writer).to receive(:close)
      allow(IO).to receive(:pipe).and_return([reader, writer])

      expect(Process).to receive(:spawn).with('say', '-v', 'Anna', in: reader, out: File::NULL, err: File::NULL).and_return(42)
      expect(Process).to receive(:detach).with(42)
      expect(Vox.speak(text: 'Hallo', voice: 'Anna')).to be(true)
    end

    it 'omits -v when no voice is given' do
      reader = double('reader', close: nil)
      writer = double('writer')
      allow(writer).to receive(:write)
      allow(writer).to receive(:close)
      allow(IO).to receive(:pipe).and_return([reader, writer])

      expect(Process).to receive(:spawn).with('say', in: reader, out: File::NULL, err: File::NULL).and_return(7)
      expect(Process).to receive(:detach).with(7)
      expect(Vox.speak(text: 'Hallo')).to be(true)
    end
  end
end