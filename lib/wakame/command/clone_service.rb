
class Wakame::Command::CloneService
  include Wakame::Command

  attr_reader :prop_name

  def parser(args)
    raise CommandArgumentError, "Property name has to be given " if args.size < 1
    @prop_name = args.shift
  end

end
