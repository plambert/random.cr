#!/usr/bin/env cryun

require "random/*"
require "base64"
require "uri"

CLI_HELP = <<-HELP
#{PROGRAM_NAME} - create random data

usage: #{PROGRAM_NAME} [options] [bytes]

options:

  bytes                    Integer number of bytes to output (default: #{Random::CLI::DEFAULT_BYTES})

  --raw                    Output the raw bytes with no newline or other terminator

HELP

class LFIO < IO
  property width : Int32
  property io : IO
  property column : Int32

  def initialize(@width, @io, @column = 0)
  end

  def write(slice : Bytes) : Nil
    slice.each do |byte|
      @io << byte.unsafe_chr
      @column += 1
      if @column > @width
        @io << '\n'
        @column = 0
      end
    end
  end

  def read(slice : Bytes) : Nil
    raise RuntimeError.new "cannot read LFIO"
  end
end

# Command line tool for generating random data
module Random
  enum Source
    Secure
    ISAAC
    PCG32
    DevRandom
    DevUrandom
  end

  enum Format
    Base64
    Raw
    HexUpper
    HexLower
    URLEncoded
    URLBase64

    def newline?
      !self.raw?
    end
  end

  class CLI
    VERSION       = "0.1.0"
    DEFAULT_BYTES = 16_u32
    # BUFFER_SIZE        =    256
    # BASE64_BUFFER_SIZE =    235 # multiple of 45

    property source : Source = Source::Secure
    property seed : UInt64 = 0_u64
    property sequence : UInt64 = 0_u64
    property format : Format = Format::HexLower
    property bytes : UInt32 = DEFAULT_BYTES
    property! random : Random
    property! dev_input : IO
    # property buffer : Bytes = Bytes.new(BUFFER_SIZE)
    property linefeed : Int32? = nil
    property io : IO

    def initialize(opts = ARGV.dup)
      _seed : UInt64? = nil
      _sequence : UInt64? = nil

      while opt = opts.shift?
        case opt
        when "--secure"
          @source = Source::Secure
        when "--pcg32", "--no-secure"
          @source = Source::PCG32
        when "--isaac"
          @source = Source::ISAAC
        when "--dev-random", "--dev"
          @source = Source::DevRandom
        when "--dev-urandom"
          @source = Source::DevUrandom
        when "--help", "-h"
          raise ArgumentError.new "#{opt}: no help available"
        when "--seed"
          _seed = opts.shift.to_u64
        when "--sequence"
          _sequence = opts.shift.to_u64
        when "--base64"
          @format = Format::Base64
        when "--url-base64", "--url64"
          @format = Format::URLBase64
        when "--raw"
          @format = Format::Raw
        when "--hex", "--hex-lower"
          @format = Format::HexLower
        when "--hex-upper"
          @format = Format::HexUpper
        when "--url-encoded"
          @format = Format::URLEncoded
        when "--line-feed"
          @linefeed = opts.shift.to_i
        when %r{^0*[1-9]\d*$}
          @bytes = opt.to_u32
        else
          raise ArgumentError.new "#{opt}: unknown option"
        end
      end

      if _seed && !@source.isaac? && !@source.pcg32?
        raise ArgumentError.new "seed only valid with --isaac or --pcg32"
      end

      if _sequence && !@source.pcg32?
        raise ArgumentError.new "sequence only valid with --pcg32"
      end

      if @format == Format::Raw && STDOUT.tty?
        raise RuntimeError.new "will not output raw bytes to a TTY"
      end

      case @source
      in .pcg32?
        @random = if _seed
                    Random::PCG32.new _seed, _sequence || 0_u64
                  else
                    Random::PCG32.new
                  end
      in .isaac?
        @random = if _seed
                    Random::ISAAC.new [_seed]
                  else
                    Random::ISAAC.new
                  end
      in .secure?
        # do nothing
      in .dev_random?
        @dev_input = File.open "/dev/random", "r"
      in .dev_urandom?
        @dev_input = File.open "/dev/urandom", "r"
      end

      @sequence = _sequence if _sequence
      @seed = _seed if _seed

      @io = if lf = @linefeed
              LFIO.new(lf, STDOUT)
            else
              STDOUT
            end
    end

    def run
      # count = @bytes
      # bufsize = case format
      #           when .base64?, .url_base64?
      #             BASE64_BUFFER_SIZE
      #           else
      #             BUFFER_SIZE
      #           end
      # while count > bufsize
      #   write_bytes bufsize
      #   count -= bufsize
      # end
      buffer = Bytes.new(@bytes)
      write_bytes buffer
      STDOUT << '\n' if STDOUT.tty? && @format.newline?
    end

    def write_bytes(buf)
      # buf = @buffer[0...count]
      random_bytes(buf)
      case format
      in .base64?
        io << Base64.encode(buf).gsub('\n', "")
      in .url_base64?
        io << Base64.urlsafe_encode(buf).gsub('\n', "")
      in .raw?
        io.write buf
      in .hex_upper?
        io << buf.hexstring.upcase
      in .hex_lower?
        io << buf.hexstring.downcase
      in .url_encoded?
        buf.each do |byte|
          char = byte.unsafe_chr
          case char
          when .ascii_alphanumeric?, '_', '.', '-', '~', '/'
            io << char
          else
            io << '%'
            io.printf "%02X", byte
          end
        end
      end
    end

    def random_bytes(buf)
      case source
      in .secure?
        Random::Secure.random_bytes(buf)
      in .isaac?, .pcg32?
        self.random.random_bytes(buf)
      in .dev_random?, .dev_urandom?
        self.dev_input.read_fully(buf)
      end
    end
  end
end

cli = Random::CLI.new
cli.run
