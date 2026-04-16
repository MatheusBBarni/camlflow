module Driver = Parsing_driver

type error = Driver.error

let parse_string = Driver.parse_string
let parse_file = Driver.parse_file
let parse_module = Driver.parse_module
