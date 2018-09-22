require 'optparse'

class Parser
  
  def process_args 
  	@options = {}
  	OptionParser.new do |parser| 
  	  parser.banner = help_banner 
  	  parser.on("-h" ,"--help", "Display this help and do nothing else") do 
  	  	puts parser
  	  end	
  	  parser.on("-i", "--include-top", "Include specified asset in the output") do 
  	    @options[:include_top] = true	
  	  end   
  	  parser.on("-g", "--group-id GROUP_ID", "groupId coordinate") do |value|
        @options[:group_id] = value
      end	
  	end.parse!
  end

  def options 
  	@options
  end

  private 

  def help_banner 
  	banner = "repominer version 1.0.0\n"
  	banner += "  Starting with the specified coordinates: group id, artifact id, version, [classifier],\n"
  	banner += "  this script 'mines' the specified local repository to find all the dependencies and writes their\n"
  	banner += "  coordinates to stdout, one line per, as:\n\n"
  	banner += "  groupId artifactId version[-classifier]\n\n"
  	banner += "  The intent is to pipe the output into another script\n"
  	banner += "  or program that needs to process assets from the repository.\n\n"
  	banner += "Usage: repominer [options]\n" 
  end 
end

p = Parser.new
#p.process_args [ "--include-top", "--group-id", "myGroupId" ]
p.process_args 
puts "options: #{p.options}"
