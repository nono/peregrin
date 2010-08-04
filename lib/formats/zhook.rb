class Peregrin::Zhook

  FILE_EXT = ".zhook"
  INDEX_PATH = "index.html"
  COVER_PATH = "cover.png"
  BODY_XPATH = '/html/body'

  # Raises an exception if file at path is not a valid Zhook. Otherwise
  # returns true.
  #
  def self.validate(path)
    raise FileNotFound.new(path)  unless File.file?(path)
    raise WrongExtension.new(path)  unless File.extname(path) == FILE_EXT
    begin
      zf = Zip::ZipFile.open(path)
    rescue
      raise NotAZipArchive.new(path)
    end

    unless zf.find_entry(INDEX_PATH)
      raise MissingIndexHTML.new(path)
    end

    unless zf.find_entry(COVER_PATH)
      raise MissingCoverPNG.new(path)
    end

    doc = Nokogiri::HTML::Document.parse(zf.read(INDEX_PATH))
    raise IndexHTMLRootHasId.new(path)  if doc.root['id']

  ensure
    zf.close  if zf
  end


  # Unzips the file at path, generates a simple book object, passes to new.
  #
  def self.read(path)
    validate(path)
    book = Peregrin::Book.new
    Zip::ZipFile.open(path) { |zf|
      book.components.push(INDEX_PATH => zf.read(INDEX_PATH))
      Zip::ZipFile.foreach(path) { |entry|
        ze = entry.to_s
        book.media.push(ze)  unless ze == INDEX_PATH
      }
    }
    doc = Nokogiri::HTML::Document.parse(book.components.first.values.first)
    doc.css('html head meta[name]').each { |meta|
      name = meta['name']
      content = meta['content']
      if book.metadata[name]
        book.metadata[name] += "\n" + content
      else
        book.metadata[name] = content
      end
    }

    new(book)
  end


  # Stitches together components of the internal book.
  #
  def initialize(book)
    @book = book

    if @book.components.length > 1
      stitch_components(@book)
    end

    consolidate_metadata(@book)

    @book.contents = outline_book(index)
  end


  # Writes the internal book object to a .zhook file at the given path.
  #
  def write(path)
  end


  # Returns the internal book object.
  #
  def to_book(options = {})
    bk = Marshal.load(Marshal.dump(@book))

    # XPath => URI mapping tools
    cmpt_xpaths = []

    # Componentizing.
    if options[:componentize]
      componentizer = Peregrin::Componentizer.new(index)
      componentizer.process(index.root.at_css('body'))
      bk.components = componentizer.component_xpaths.collect { |xpath|
        cmpt_xpaths.push(xpath)
        doc = componentizer.generate_component(xpath)
        { uri_for_xpath(xpath, cmpt_xpaths) => htmlize(doc) }
      }
    else
      cmpt_xpaths.push(BODY_XPATH)
      bk.components = [{ uri_for_xpath(BODY_XPATH) => htmlize(index) }]
    end

    # Outlining.
    bk.contents = outline_book(index, cmpt_xpaths)

    bk
  end


  protected

    def index
      @index_document ||= Nokogiri::HTML::Document.parse(
        @book.components.first.values.first
      )
    end


    # Takes a book with multiple components and joins them together,
    # by creating article elements from every body element and appending them
    # to the body of the first component.
    def stitch_components(book)
      node = Nokogiri::XML::Node.new('article', index)
      bdy = index.at_xpath(BODY_XPATH)
      bdy.children.each { |ch|
        node.add_child(ch)
      }
      bdy.add_child(node)

      book.components.shift
      while cmpt = book.components.shift
        str = cmpt.values.first
        doc = Nokogiri::HTML::Document.parse(str)
        art = doc.at_xpath(BODY_XPATH)
        art.name = 'article'
        bdy.add_child(art)

        # TODO: what other elements from the head should we import?
        # - link tags?
        # - meta tags?
      end
      book.components = [{ uri_for_xpath(BODY_XPATH) => htmlize(index) }]
    end


    # Takes the metadata out of the book and ensures that there are matching
    # meta tags in the index document.
    #
    def consolidate_metadata(book)
      head = index.at_xpath('/html/head')
      head.css('meta[name]').each { |meta| meta.remove }
      book.metadata.each_pair { |name, content|
        content.split(/\n/).each { |val|
          meta = Nokogiri::XML::Node.new('meta', index)
          meta['name'] = name
          meta['content'] = val
          head.add_child(meta)
        }
      }
    end


    def outline_book(doc, cmpt_xpaths = [BODY_XPATH])
      unless defined?(@outliner) && @outliner
        @outliner = Peregrin::Outliner.new(doc)
        @outliner.process(doc.root)
      end

      curse = lambda { |sxn|
        # Find the component parent
        n = sxn.node || sxn.heading
        while n && n.respond_to?(:parent)
          break if cmptURI = uri_for_xpath(n.path, cmpt_xpaths)
          n = n.parent
        end

        if cmptURI
          # get URI for section
          sid = sxn.heading['id'] if sxn.heading
          sid ||= sxn.node['id'] if sxn.node
          cmptURI += "#"+sid if sid && !sid.empty?

          chapter = {
            :title => sxn.heading_text,
            :src => cmptURI
          }

          # identify any relevant child sections
          children = sxn.sections.collect { |ch|
            curse.call(ch) unless ch.empty?
          }.compact

          chapter[:children] = children if children.any?

          chapter
        else
          nil
        end
      }

      curse.call(@outliner.result_root)[:children]
    end


    def uri_for_xpath(xpath, cmpt_xpaths = [BODY_XPATH])
      return nil  unless cmpt_xpaths.include?(xpath)
      i = cmpt_xpaths.index(xpath)
      (i == 0) ? "index.html" : "part#{"%03d" % i}.html"
    end


    def htmlize(doc)
      "<!DOCTYPE html>\n"+ doc.root.to_html
    end


  class ValidationError < ::RuntimeError

    def initialize(path = nil)
      @path = path
    end

  end

  class FileNotFound < ValidationError; end
  class WrongExtension < ValidationError; end
  class NotAZipArchive < ValidationError; end
  class MissingIndexHTML < ValidationError; end
  class MissingCoverPNG < ValidationError; end
  class IndexHTMLRootHasId < ValidationError; end

end