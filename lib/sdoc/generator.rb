require 'erb'
require 'pathname'
require 'fileutils'
require 'json'

require "rdoc"
require_relative "rdoc_monkey_patches"

require 'sdoc/templatable'
require 'sdoc/helpers'
require 'sdoc/search_index'
require 'sdoc/version'

class RDoc::ClassModule
  def with_documentation?
    document_self_or_methods || classes_and_modules.any?{ |c| c.with_documentation? }
  end
end

class RDoc::Options
  attr_accessor :github
  attr_accessor :search_index
end

class RDoc::Generator::SDoc
  RDoc::RDoc.add_generator self

  DESCRIPTION = 'Searchable HTML documentation'

  include ERB::Util
  include SDoc::Templatable
  include SDoc::Helpers

  TREE_FILE = File.join 'panel', 'tree.js'

  FILE_DIR = 'files'
  CLASS_DIR = 'classes'

  RESOURCES_DIR = File.join('resources', '.')

  attr_reader :base_dir

  attr_reader :options

  ##
  # The RDoc::Store that is the source of the generated content

  attr_reader :store

  def self.setup_options(options)
    opt = options.option_parser

    opt.separator nil
    opt.separator "SDoc generator options:"

    opt.separator nil
    opt.on("--github", "-g",
            "Generate links to github.") do |value|
      options.github = true
    end

    opt.separator nil
    opt.on("--version", "-v", "Output current version") do
      puts SDoc::VERSION
      exit
    end

    options.title = [
      ENV["HORO_PROJECT_NAME"],
      ENV["HORO_BADGE_VERSION"] || ENV["HORO_PROJECT_VERSION"],
      "API documentation"
    ].compact.join(" ")
  end

  def initialize(store, options)
    @store   = store
    @options = options
    if @options.respond_to?('diagram=')
      @options.diagram = false
    end
    @options.pipe = true

    @original_dir = Pathname.pwd
    @template_dir = Pathname.new(options.template_dir)
    @base_dir = options.root
  end

  def generate
    @outputdir = Pathname.new(@options.op_dir).expand_path(@base_dir)
    FileUtils.mkdir_p @outputdir
    @files = @store.all_files.sort
    @classes = @store.all_classes_and_modules.sort

    # Now actually write the output
    copy_resources
    generate_search_index
    generate_file_links
    generate_class_tree

    generate_index_file
    generate_file_files
    generate_class_files
  end

  def class_dir
    CLASS_DIR
  end

  def file_dir
    FILE_DIR
  end

  ### Determines index page based on @options.main_page (or lack thereof)
  def index
    @index ||= begin
      path = @original_dir.join(@options.main_page || @options.files.first || "").expand_path
      file = @files.find { |file| @options.root.join(file.full_name) == path }
      raise "Could not find main page #{path.to_s.inspect} among rendered files" if !file

      file = file.dup
      file.path = ""

      file
    end
  end

  protected
  ### Output progress information if debugging is enabled
  def debug_msg( *msg )
    return unless $DEBUG_RDOC
    $stderr.puts( *msg )
  end

  ### Create index.html with frameset
  def generate_index_file
    debug_msg "Generating index file in #{@outputdir}"
    templatefile = @template_dir + 'index.rhtml'
    outfile      = @outputdir + 'index.html'

    render_template(templatefile, binding, outfile)
  end

  ### Generate a documentation file for each class
  def generate_class_files
    debug_msg "Generating class documentation in #{@outputdir}"
    templatefile = @template_dir + 'class.rhtml'

    @classes.each do |klass|
      debug_msg "  working on %s (%s)" % [ klass.full_name, klass.path ]
      outfile     = @outputdir + klass.path

      debug_msg "  rendering #{outfile}"
      render_template(templatefile, binding, outfile)
    end
  end

  ### Generate a documentation file for each file
  def generate_file_files
    debug_msg "Generating file documentation in #{@outputdir}"
    templatefile = @template_dir + 'file.rhtml'

    @files.each do |file|
      outfile     = @outputdir + file.path
      debug_msg "  working on %s (%s)" % [ file.full_name, outfile ]

      debug_msg "  rendering #{outfile}"
      render_template(templatefile, binding, outfile)
    end
  end

  ### Generate file with links for the search engine
  def generate_file_links
    debug_msg "Generating search engine index in #{@outputdir}"
    templatefile = @template_dir + 'file_links.rhtml'
    outfile      = @outputdir + 'panel/file_links.html'

    render_template(templatefile, binding, outfile)
  end

  ### Create class tree structure and write it as json
  def generate_class_tree
    debug_msg "Generating class tree"
    topclasses = @classes.select {|klass| !(RDoc::ClassModule === klass.parent) }
    tree = generate_file_tree + generate_class_tree_level(topclasses)
    file = @outputdir + TREE_FILE
    debug_msg "  writing class tree to %s" % file
    File.open(file, "w", 0644) do |f|
      f.write('var tree = '); f.write(tree.to_json(:max_nesting => 0))
    end unless @options.dry_run
  end

  ### Recursivly build class tree structure
  def generate_class_tree_level(classes, visited = {})
    tree = []
    classes.select do |klass|
      !visited[klass] && klass.with_documentation?
    end.sort.each do |klass|
      visited[klass] = true
      item = [
        klass.name,
        klass.document_self_or_methods ? klass.path : '',
        klass.module? ? '' : (klass.superclass ? " < #{String === klass.superclass ? klass.superclass : klass.superclass.full_name}" : ''),
        generate_class_tree_level(klass.classes_and_modules, visited)
      ]
      tree << item
    end
    tree
  end

  def generate_search_index
    debug_msg "Generating search index"
    unless @options.dry_run
      index = SDoc::SearchIndex.generate(@store.all_classes_and_modules)

      @outputdir.join("js/search-index.js").open("w") do |file|
        file.write("export default ")
        JSON.dump(index, file)
        file.write(";")
      end
    end
  end

  ### Copy all the resource files to output dir
  def copy_resources
    resources_path = @template_dir + RESOURCES_DIR
    debug_msg "Copying #{resources_path}/** to #{@outputdir}/**"
    FileUtils.cp_r resources_path.to_s, @outputdir.to_s unless @options.dry_run
  end

  class FilesTree
    attr_reader :children
    def add(path, url)
      path = path.split(File::SEPARATOR) unless Array === path
      @children ||= {}
      if path.length == 1
        @children[path.first] = url
      else
        @children[path.first] ||= FilesTree.new
        @children[path.first].add(path[1, path.length], url)
      end
    end
  end

  def generate_file_tree
    if @files.length > 1
      @files_tree = FilesTree.new
      @files.each do |file|
        @files_tree.add(file.relative_name, file.path)
      end
      [['', '', 'files', generate_file_tree_level(@files_tree)]]
    else
      []
    end
  end

  def generate_file_tree_level(tree)
    tree.children.keys.sort.map do |name|
      child = tree.children[name]
      if String === child
        [name, child, '', []]
      else
        ['', '', name, generate_file_tree_level(child)]
      end
    end
  end
end
