# frozen_string_literal: true

require_relative "mizlab/version"
require "set"
require "bio"
require "stringio"
require "rexml/document"

module Mizlab
  class << self
    # Get entry as String. You can also give a block.
    # @param  [String/Array] accessions Accession numbers like ["NC_012920", ...].
    # @return [String] Entry as string.
    # @yield  [String] Entry as string.
    def getent(accessions, is_protein = false)
      accessions = accessions.is_a?(String) ? [accessions] : accessions
      accessions.each do |acc|
        ret = is_protein ? fetch_protein(acc) : fetch_nucleotide(acc)
        if block_given?
          yield ret
        else
          return ret
        end
        sleep(0.37) # Using 0.333... seconds, sometimes hit the NCBI rate limit
      end
    end

    # Fetch data via genbank. You can also give a block.
    # @param  [String/Array] accessions Accession numbers Like ["NC_012920", ...].
    # @param  [Bool] is_protein wheather the accession is protein. Default to true.
    # @return [Bio::GenBank] GenBank object.
    # @yield  [Bio::GenBank] GenBank object.
    def getobj(accessions, is_protein = false)
      getent(accessions, is_protein) do |entry|
        parse(entry) do |o|
          if block_given?
            yield o
          else
            return o
          end
        end
      end
    end

    # Save object.
    # @param  [String] filename Filepath from executed source.
    # @param  [Bio::DB] obj Object which inherits from `Bio::DB`.
    # @return [nil]
    def savefile(filename, obj)
      if File.exists?(filename)
        yes = Set.new(["N", "n", "no"])
        no = Set.new(["Y", "y", "yes"])
        loop do
          print("#{filename} exists already. Overwrite? [y/n] ")
          inputed = gets.rstrip
          if yes.include?(inputed)
            return
          elsif no.include?(inputed)
            break
          end
          puts("You should input 'y' or 'n'")
        end
      end
      File.open(filename, "w") do |f|
        obj.tags.each do |t|
          f.puts(obj.get(t))
        end
      end
    end

    # Calculate coordinates from sequence
    # @param  [Bio::Sequence] sequence sequence
    # @param  [Hash] mappings Hash formated {String => [Float...]}. All of [Float...] must be have same dimention.
    # @param  [Hash] weights Weights for some base combination.
    # @param  [Integer] Size of window when scanning sequence. If not give this, will use `mappings.keys[0].length -1`.
    # @return [Array] coordinates like [[dim1...], [dim2...]...].
    def calculate_coordinates(sequence, mappings,
                              weights = nil, window_size = nil)
      # error detections
      if weights.is_a?(Hash) && window_size.nil?
        keys = weights.keys
        expect_window_size = keys[0].length
        if keys.any? { |k| k.length != expect_window_size }
          raise TypeError, "When not give `window_size`, `weights` must have same length keys"
        end
      end
      n_dimention = mappings.values[0].length
      if mappings.values.any? { |v| v.length != n_dimention }
        raise TypeError, "All of `mappings`.values must have same size"
      end

      mappings.each do |k, v|
        mappings[k] = v.map(&:to_f)
      end

      window_size = (if window_size.nil?
        unless weights.nil?
          weights.keys[0].length
        else
          3 # default
        end
      else
        window_size
      end)
      window_size -= 1
      weights = weights.nil? ? {} : weights
      weights.default = 1.0
      coordinates = Array.new(n_dimention) { [0.0] }
      sequence.length.times do |idx|
        start = idx < window_size ? 0 : idx - window_size
        vector = mappings[sequence[idx]].map { |v| v * weights[sequence[start..idx]] }
        vector.each_with_index do |v, j|
          coordinates[j].append(coordinates[j][-1] + v)
        end
      end
      return coordinates
    end

    # Compute local patterns from coordinates.
    # @param  [Array] x_coordinates coordinates on x.
    # @param  [Array] y_coordinates coordinates on y.
    # @return [Array] Local pattern histgram (unnormalized).
    def local_patterns(x_coordinates, y_coordinates)
      length = x_coordinates.length
      if length != y_coordinates.length
        raise TypeError, "The arguments must have same length."
      end

      filled_pixs = Set.new
      0.upto(length - 2) do |idx|
        filled_pixs += bresenham(x_coordinates[idx].truncate, y_coordinates[idx].truncate,
                                 x_coordinates[idx + 1].truncate, y_coordinates[idx + 1].truncate)
      end

      local_pattern_list = [0] * 512
      get_patterns(filled_pixs) do |pix|
        local_pattern_list[convert(pix)] += 1
      end
      return local_pattern_list
    end

    # Fetch Taxonomy information from Taxonomy ID. can be give block too.
    # @param  [String/Integer] taxonid Taxonomy ID, or Array of its.
    # @return [Hash] Taxonomy informations.
    # @yield  [Hash] Taxonomy informations.
    def fetch_taxon(taxonid)
      taxonid = taxonid.is_a?(Array) ? taxonid : [taxonid]
      taxonid.each do |id|
        obj = Bio::NCBI::REST::EFetch.taxonomy(id, "xml")
        hashed = xml_to_hash(REXML::Document.new(obj).root)
        if block_given?
          yield hashed[:TaxaSet][:Taxon][:LineageEx][:Taxon]
        else
          return hashed[:TaxaSet][:Taxon][:LineageEx][:Taxon]
        end
      end
    end

    private

    def fetch_protein(accession)
      return Bio::NCBI::REST::EFetch.protein(accession)
    end

    def fetch_nucleotide(accession)
      return Bio::NCBI::REST::EFetch.nucleotide(accession)
    end

    # get patterns from filled pixs.
    # @param [Set] filleds filled pix's coordinates.
    # @yield [binaries] Array like [t, f, t...].
    def get_patterns(filleds)
      unless filleds.is_a?(Set)
        raise TypeError, "The argument must be Set"
      end

      centers = Set.new()
      filleds.each do |focused|
        get_centers(focused) do |center|
          if centers.include?(center)
            next
          end
          centers.add(center)
          binaries = []
          -1.upto(1) do |dy|
            1.downto(-1) do |dx|
              binaries.append(filleds.include?([center[0] + dx, center[1] + dy]))
            end
          end
          yield binaries
        end
      end
    end

    # get center coordinates of all window that include focused pixel
    # @param  [Array] focused coordinate of focused pixel
    # @yield [Array] center coordinates of all window
    def get_centers(focused)
      -1.upto(1) do |dy|
        1.downto(-1) do |dx|
          yield [focused[0] + dx, focused[1] + dy]
        end
      end
    end

    # Convert binary array to interger
    # @param  [Array] binaries Array of binaries
    # @return [Integer] converted integer
    def convert(binaries)
      unless binaries.all? { |v| v.is_a?(TrueClass) || v.is_a?(FalseClass) }
        raise TypeError, "The argument must be Boolean"
      end
      rst = 0
      binaries.reverse.each_with_index do |b, i|
        if b
          rst += 2 ** i
        end
      end
      return rst
    end

    # Compute fill pixels by bresenham algorithm
    # @param  [Interger] x0 the start point on x.
    # @param  [Interger] y0 the start point on y.
    # @param  [Interger] x1 the end point on x.
    # @param  [Interger] x1 the end point on y.
    # @return [Array] filled pixels
    # ref https://aidiary.hatenablog.com/entry/20050402/1251514618 (japanese)
    def bresenham(x0, y0, x1, y1)
      if ![x0, y0, x1, y1].all? { |v| v.is_a?(Integer) }
        raise TypeError, "All of arguments must be Integer"
      end

      dx = x1 - x0
      dy = y1 - y0
      step_x = dx.positive? ? 1 : -1
      step_y = dy.positive? ? 1 : -1
      dx, dy = [dx, dy].map { |x| (x * 2).abs }

      lines = [[x0, y0]]

      if dx > dy
        fraction = dy - dx / 2
        while x0 != x1
          if fraction >= 0
            y0 += step_y
            fraction -= dx
          end
          x0 += step_x
          fraction += dy
          lines << [x0, y0]
        end
      else
        fraction = dx - dy / 2
        while y0 != y1
          if fraction >= 0
            x0 += step_x
            fraction -= dx
          end
          y0 += step_y
          fraction += dx
          lines << [x0, y0]
        end
      end
      return lines
    end

    # Parse fetched data.
    # @param  [String] entries Entries as string
    # @yield  [Object] Object that match entry format.
    def parse(entries)
      Bio::FlatFile.auto(StringIO.new(entries)).each_entry do |e|
        yield e
      end
    end

    # Convert XML to Hash.
    # @param  [REXML::Document] element XML object.
    # @return [Hash] Hash that converted from xml.
    def xml_to_hash(element)
      value = (if element.has_elements?
        children = {}
        element.each_element do |e|
          children.merge!(xml_to_hash(e)) { |k, v1, v2| v1.is_a?(Array) ? v1 << v2 : [v1, v2] }
        end
        children
      else
        element.text
      end)
      return { element.name.to_sym => value }
    end
  end
end
