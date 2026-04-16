module Driver = Parsing_driver

type error = Driver.error

let parse_string = Driver.parse_string
