require_relative "./repominer/version"
require_relative "./coordinates"
require_relative "./logging"
require 'getoptlong'
require 'oga'

# Read a local Maven-style Nexus repository and find all the
# dependencies for a given asset. Write the coordinates of each dependency to stdout,
# one per line like this:

# groupId artifactId version-classifier
#
# The output can be piped into another script or program.
module Repominer
  include Logging
  attr_accessor :repository
  attr_accessor :options

  class AssetNotFoundError < StandardError
  end 

  RECURSION_LIMIT = 5
  DEFAULT_REPOSITORY = "#{ENV['HOME']}/.m2/repository"
  DEFAULT_LOG_FILE = "#{ENV['HOME']}/repominer.log"
  XPATH_TO_XMLNS = '/project[@xmlns]'
  XPATH_TO_PROPERTIES = '//properties'
  XPATH_TO_PARENT = '//parent'
  XPATH_TO_DEPENDENCIES = '//dependencies'
  XPATH_TO_NEXT_DEPENDENCY = '//dependency'
  XMLNS = 'xmlns'
  POM_NAMESPACE = 'http://maven.apache.org/POM/4.0.0'
  PROPERTIES_PREFIX = '${'
  EMPTY_STRING = '' 

  # See if the path to the repository exists and is a directory.
  # If not, return a string 'nil' for logging.
  def find_repository path_to_repository
  	path = path_to_repository == nil ? 'nil' : path_to_repository
  	raise StandardError, sprintf(MESSAGE_NO_LOCAL_REPOSITORY_FOUND, path) unless File.directory?(path)
  	path
  end

  def find_dependencies_for asset  	
    $LOG.debug "[find_dependencies_for] <#{asset}>" if options[:debug] == true
    doc = ingest_pom_file asset 
    dependencies_section = find_dependencies_section_in doc
    coordinates_list = process_dependencies_from dependencies_section
    coordinates_list.each do |coordinates|
      if coordinates.version.empty? 
      	$LOG.debug "[find_dependencies_for] skipping #{coordinates.inspect} because no version" if options[:debug] == true
      else
        $LOG.debug "[find_dependencies_for] looking for #{coordinates.inspect}" if options[:debug] == true
        asset = find_asset(
          @repository, 
          coordinates.group_id,
      	  coordinates.artifact_id,
      	  coordinates.version,
      	  nil)
        find_dependencies_for asset unless asset == nil
      end  
    end  
  end

  # Construct the file path to the directory that contains the pom file and asset file
  def find_asset path_to_repository, group_id, artifact_id, version, classifier 
  	version_with_classifier = classifier == nil ? version : "#{version}-#{classifier}"
  	subpath_to_asset = "#{group_id.gsub('.','/')}/#{artifact_id}/#{version_with_classifier}"
  	path_to_asset = "#{path_to_repository}/#{subpath_to_asset}"

  	path_to_pom_file = nil
    if File.directory?(path_to_asset)
      path_to_pom_file = "#{path_to_asset}/#{artifact_id}-#{version_with_classifier}.pom"
      if File.exists?(path_to_pom_file)
      else 
      	$LOG.warn sprintf(MESSAGE_NO_POM_FILE_FOUND_FOR_ASSET, path_to_pom_file)
      end 
    else 
      $LOG.warn sprintf(MESSAGE_ASSET_NOT_FOUND, path_to_asset)
    end     	
    path_to_pom_file
  end 

  # Load the pom file at the specified path into memory as an XML document.
  # Return nil if the file does not exist or if it does not appear to contain a POM.
  def ingest_pom_file path_to_pom_file 
  	begin 
  	  doc = Oga.parse_xml(File.open(path_to_pom_file))
      $LOG.warn sprintf(MESSAGE_NOT_A_POM, path_to_pom_file) unless doc.xpath(XPATH_TO_XMLNS).first.get(XMLNS).eql?(POM_NAMESPACE)
  	rescue StandardError => error 
  	  $LOG.warn sprintf(MESSAGE_NO_POM_FILE_FOUND, path_to_pom_file)
  	end   
  	@current_pom = doc
  	doc   
  end 

  # Return the XML Element of the dependencies section of the provided pom document
  def find_dependencies_section_in pom 
  	pom.xpath(XPATH_TO_DEPENDENCIES)
  end 

  # Return the XML Element of the next dependency in the dependency section of a pom.
  # The argument is an Oga::XML::NodeSet, which behaves similarly to a Ruby array.
  def process_dependencies_from dependencies_section
  	coordinates_list = []
  	dependencies_section.each do |dependency|
  	  dependency.children.select {|element| element.class == Oga::XML::Element}.each do |element|	
      	coordinates = get_coordinates_of(element)
        coordinates_list << coordinates unless coordinates == nil
      end
    end  
    coordinates_list == nil ? [] : coordinates_list 
  end 

  # Return a Coordinates object containing groupId, artifactId, and version.
  # If there is no version, it means the version is specified in a dependencyManagement
  # section of another pom; in that case we return nil and ignore this entry.
  def get_coordinates_of dependency
#  	$LOG.debug "[get_coordinates_of] <#{dependency.inspect}" if options[:debug] == true
    coordinates = Coordinates.new
    dependency.children.select {|node| node.class == Oga::XML::Element}.each do |node|
      case node.name
        when 'groupId' 
          coordinates.group_id = node.text
  	    when 'artifactId' 
  	      coordinates.artifact_id = node.text 
   	    when 'version' 
   	      @recursion_count = 0
  	      coordinates.version = get_version @current_pom, coordinates.group_id, coordinates.artifact_id, node.text 
      end 	  
    end
    coordinates.version == nil ? nil : coordinates
  end 

  def get_version current_pom, dep_group_id, dep_artifact_id, dep_version 
    @recursion_count += 1
    if @recursion_count > RECURSION_LIMIT
      return nil 
    end 
  	return nil if dep_version.empty?
  	return dep_version unless dep_version.start_with? PROPERTIES_PREFIX
  	# strip off ${...} if there's no property by this name you get empty string, not nil
  	version = current_pom.xpath("#{XPATH_TO_PROPERTIES}/#{dep_version[1..-1].tr('{}','')}").text 
    return version unless version == EMPTY_STRING
    parent_pom = find_parent_pom current_pom
    if parent_pom == nil 
      $LOG.debug "[get_version] returning nil because parent pom could not be found" if options[:debug] == true
      return nil 
    end 
    dependencies = parent_pom.xpath(XPATH_TO_DEPENDENCIES)
    $LOG.debug "[get_version] xpath: //dependencies/dependency[artifactId[text()=\"#{dep_artifact_id}\"]]" if options[:debug] == true
    dependency = parent_pom.xpath("//dependencies/dependency[artifactId[text()=\"#{dep_artifact_id}\"]]")
    version = get_version parent_pom, dep_group_id, dep_artifact_id, dep_version if dependency.empty? 
    if options[:debug] == true 
      xversion = (version == nil) ? 'nil' : (version == '') ? 'empty' : version
      $LOG.debug "[get_version] version: <#{xversion}>"
    end 

    version
  end 	

  def find_parent_pom current_pom 
#    $LOG.debug "\n find_parent_pom: current_pom is:\n#{current_pom.inspect}\n" if options[:debug] == true
    parent_group_id = current_pom.xpath("#{XPATH_TO_PARENT}/groupId").text
    parent_artifact_id = current_pom.xpath("#{XPATH_TO_PARENT}/artifactId").text
    parent_version = current_pom.xpath("#{XPATH_TO_PARENT}/version").text
    $LOG.debug "[find_parent_pom] parent coordinates: groupId #{parent_group_id}, artifactId #{parent_artifact_id}, version #{parent_version}" if options[:debug] == true
    if parent_group_id.empty? || parent_artifact_id.empty? || parent_version.empty? 
      $LOG.debug "[find_parent_pom] returning nil because can't identify parent pom coordinates" if options[:debug] == true
      return nil
    end
    path_to_parent_pom = "#{@repository}/#{parent_group_id.gsub('.','/')}/#{parent_artifact_id}/#{parent_version}/#{parent_artifact_id}-#{parent_version}.pom"
    if options[:debug] == true
      $LOG.debug "[find_parent_pom] repository: <#{@repository}>"
      $LOG.debug "[find_parent_pom] path to parent pom: #{path_to_parent_pom}"
    end 
  	begin 
  	  parent_pom = Oga.parse_xml(File.open(path_to_parent_pom))
      $LOG.warn sprintf(MESSAGE_NOT_A_POM, path_to_parent_pom) unless parent_pom.xpath(XPATH_TO_XMLNS).first.get(XMLNS).eql?(POM_NAMESPACE)
  	rescue StandardError => error 
      $LOG.warn sprintf("error parsing parent pom: #{error}", path_to_parent_pom)
  	  $LOG.warn sprintf(MESSAGE_NO_POM_FILE_FOUND, path_to_parent_pom)
  	end   
    if options[:debug] == true 
#      $LOG.debug "\n\n++++++++++++++++++++"
#      $LOG.debug "parent_pom: #{parent_pom.inspect}"
    end 
    parent_pom
  end 

  # Write the coordinates to stdout.
  # groupId artifactId version separated by spaces.
  def write_output coordinates 
  	puts "#{coordinates.group_id} #{coordinates.artifact_id} #{coordinates.version}"
  end 

  # Process the command-line arguments and populate the @options hash
  def process_args 
    opts = GetoptLong.new(
      [ '--help', '-h', GetoptLong::NO_ARGUMENT ],
      [ '--group-id', '-g', GetoptLong::REQUIRED_ARGUMENT ],
      [ '--artifact-id', '-a', GetoptLong::REQUIRED_ARGUMENT ],
      [ '--version', '-v', GetoptLong::REQUIRED_ARGUMENT ],
      [ '--classifier', '-c',  GetoptLong::REQUIRED_ARGUMENT ],
      [ '--include-top', '-i', GetoptLong::NO_ARGUMENT ],
      [ '--repository', '-r', GetoptLong::REQUIRED_ARGUMENT ],
      [ '--log-file', '-l', GetoptLong::REQUIRED_ARGUMENT ],
      [ '--debug', '-d', GetoptLong::NO_ARGUMENT]
    )

    @options = {} 
    options[:include_top] = false
    options[:debug] = false
    
    opts.each do |opt, arg|
      case opt
        when '--help'
          show_help 
          exit 0
        when '--group-id'
          options[:group_id] = arg
        when '--artifact-id'
          options[:artifact_id] = arg
        when '--version'
          options[:version] = arg
        when '--classifier' 
          options[:classifier] = arg 
        when '--include-top' 
          options[:include_top] = true
        when '--repository'
          options[:repository] = arg   
        when '--log-file'
          options[:log_file] = arg  
        when '--debug' 
          options[:debug] = true
        else 
          raise ArgumentError, "Unrecognized option: #{opt} #{arg}"
      end 
    end 
    raise ArgumentError, "--group-id is required" unless options[:group_id]
    raise ArgumentError, "--artifact-id is required" unless options[:artifact_id]
    raise ArgumentError, "--version is required" unless options[:version]   
    options[:repository] = DEFAULT_REPOSITORY unless options[:repository]   
    options[:log_file] = DEFAULT_LOG_FILE unless options[:log_file]    
    $LOG = Logger.new options[:log_file], 0, 2 * 1024 * 1024
  end 

  # Emit usage help to stdout
  def show_help 
  	puts "repominer version #{VERSION}"
  	puts '  Starting with the specified coordinates: group id, artifact id, version, [classifier],'
  	puts '  this script "mines" the specified local repository to find all the dependencies and writes their'
  	puts '  coordinates to stdout, one line per, as:'
    puts ' '
  	puts '  groupId artifactId version[-classifier]'
  	puts ' '
  	puts '  The intent is to pipe the output into another script'
  	puts '  or program that needs to process assets from the repository.'
  	puts ' '
  	puts 'Usage: repominer [options]' 
  	puts '  -g | --group-id       groupId of the asset whose dependencies we want (required)'
  	puts '  -a | --artifact-id    artifactId of the asset (required)'
  	puts '  -v | --version        version of the asset (required)'
  	puts '  -c | --classifier     classifier of the asset, if any'
	puts '  -i | --include-top    include the top-level asset (the one specified) in the output (default=false)'
	puts '  -r | --repository     repository to be mined (default=$HOME/.m2/repository)'
	puts '  -l | --log-file       log file (default=$HOME/repominer.log)'
	puts '  -h | --help           display this help and do nothing else'
	puts '  -d | --debug          log information about every asset and dependency'
  end 
end
