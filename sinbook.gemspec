spec = Gem::Specification.new do |s|
  s.name = 'sinbook'
  s.version = '0.1.3'
  s.date = '2009-09-24'
  s.summary = 'simple sinatra facebook extension in 300 lines of ruby'
  s.description = 'A full-featured facebook extension for the sinatra webapp framework'
  s.homepage = "http://github.com/tmm1/sinbook"

  s.authors = ["Aman Gupta"]
  s.email = "aman@tmm1.net"

  s.has_rdoc = false

  # ruby -rpp -e' pp `git ls-files | grep -v examples`.split("\n") '
  s.files = [
    "README",
    "sinbook.gemspec",
    "lib/sinbook.rb",
    "examples/simple.rb"
  ]
end
