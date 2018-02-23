#require "JSONParser.class.nut:1.0.0"

class PrinterStatus {
    _statuspacket = null
    
    static ERROR_NONE = 0x0000
    static ERROR_NO_MEDIA = 0x0001
    static ERROR_END_MEDIA = 0x0002
    static ERROR_CUTTER_JAM = 0x0004
    static ERROR_FAN = 0x0080
    static ERROR_TRANSMISSION = 0x0400
    static ERROR_COVER_OPEN = 0x1000
    static ERROR_CANNOT_FEED = 0x4000
    static ERROR_SYSTEM = 0x8000
    
    function error() {
        local e = (_statuspacket[9] << 8) + _statuspacket[8]
        return e & 0xD487 // remove unused bits
    }
    function mediawidth() {
        return _statuspacket[10]
    }
    function medialength() {
        return _statuspacket[17]
    }
    
    static MEDIA_NONE = 0x00
    static MEDIA_CONTINUOUS = 0x0A
    static MEDIA_DIECUT = 0x0B
    
    function mediatype() {
        return _statuspacket[11]
    }
    
    static STATUS_REQUEST_REPLY = 0x00
    static STATUS_PRINT_COMPLETE = 0x01
    static STATUS_ERROR = 0x02
    static STATUS_NOTIFY = 0x05
    static STATUS_PHASE_CHANGE = 0x06 
    
    function statustype() {
        return _statuspacket[18]
    }
    
    static PHASE_WAITING = 0x00
    static PHASE_PRINTING = 0x01
    function phasetype() {
        return _statuspacket[19]
    }
    static COOLING_NONE = 0x00
    static COOLING_START = 0x03
    static COOLING_FINISH = 0x04 
    
    function notificationnumber() {
        return _statuspacket[22]
    }
    
    constructor( status ) {
        _statuspacket = status
    }
}

class BitBlob {
    _pointer = 0
    _blob = null
    
    constructor( b ) {
        _blob = b
    }
    
    function bit( n ) {
        local byte = _blob[n/8]
        local mask = 1 << (n%8)
        return byte & mask
    }
    function setbit( n, bit ) {
        local byte = _blob[n/8]
        local mask = 1 << (n%8)
        if ( bit == 0 ) {
            mask = 0xFF ^ mask
            byte = byte & mask
        }
        else {
            byte = byte | mask
        }
        _blob[n/8] = byte
    }
    function read() {
        return bit(_pointer++)
    }
    function tell() {
        return _pointer
    }
    function write( bit ) {
        setbit( _pointer++, bit)
    }
    function seek( n ) {
        _pointer = n
    }
}

class notify {
    static ON = 1;
    static OFF = 0;
    static FLASH = 2;
    static NO_CHANGE = 3; 
    
    stack = null;
    
    constructor(){
        server.log("Constructing notifier")
        stack = []
        status( OFF, OFF, OFF, "Initialized")
    }
    
    function pop(){
        if ( stack.len() > 1 ) {
            stack.pop()
            device.send("led", stack.top())
        }
    }
    
    function message() {
        return stack.top().message
    }
    
    function status(red, green, yellow, message = ""){
        local value = {}
        value.red <- red
        value.green <- green
        value.yellow <- yellow
        value.message <- message
        stack.push(value)
        server.log("sending" + value)
        device.send("led", value)
    }
}

local led = notify()

class GIF {
  version = ""
  logicalwidth = 0
  logicalheight = 0
  width = 0
  height = 0
  minbits = 0
  lzwblob = null
  image = null
  colordepth = 0

  constructor(gifblob)
  {
    image = gifblob
    lzwblob = blob()
  }

  function _readrgb() {
    local red = image.readn('b')
    local green = image.readn('b')
    local blue = image.readn('b')
  }

  function _readcolortable() {
    local ctbyte = image.readn('b')
    local hasct = (ctbyte >> 7 == 1)
    if (!hasct) {
      return null
    }
    server.log("color table byte " + ctbyte + " " + ((ctbyte & 0x7) + 1) + " " + image.tell())
    colordepth = math.pow(2,((ctbyte & 0x7) + 1))
    local backgroundcolor = image.readn('b')
    local defaultaspectratio = image.readn('b')
    server.log("color table: " + colordepth)
    for (local i = 0; i < colordepth; i++) {
      server.log("color " + image.tell())
      _readrgb()
    }
  }

  function _readcomment() {
    _readblock(function(bytes) {})
  }

  function _readgceblock() {
    image.readstring(6)
  }

  function _readblock(action ) {
    while (true){
        local blocksize = image.readn('b')
        //server.log("block " + blocksize + " " + image.tell())
        if (blocksize == 0){
          return
        }
        local bytes = image.readstring(blocksize)
        action(bytes)
      }
  }

  function _readimageblock(){
    local nwX = image.readn('w')
    local nwY = image.readn('w')
    width = image.readn('w')
    height = image.readn('w')
    server.log( "image block: " + width + " " + height + " " + image.tell())
    _readcolortable()
    minbits = image.readn('b')
    server.log( "gif minbits " + minbits)
    _readblock( function(bytes) {lzwblob.writestring(bytes)})
  }

  function extract() {
    image.seek(0)
    version = image.readstring(6)
    if ( version != "GIF89a"){
      return false
    }
    logicalwidth = image.readn('w')
    logicalheight = image.readn('w')
    _readcolortable()
    while(true) {
      local blocktype = image.readn('b')
      server.log("block header " + image.tell())
      switch( blocktype) {
        case 0x21: // extension block
            server.log("extn block")
            local extblocktype = image.readn('b')
            if (extblocktype == 0xF9 ){
              // graphic control extension
              server.log("gcs block " + image.tell())
              _readgceblock()
            }
            if (extblocktype == 0xFE ){
              // comment extension
              server.log("comment")
              _readcomment()
            }
            else {
              // unknown block
              server.log("unknown extn block " + extblocktype + " " + image.tell())
              _readblock(image, function(bytes) {})
            }
            break;
        case 0x2c: // image
            server.log("image block " + image.tell())
            _readimageblock()
            break;
        case 0x3b: // trailer
            server.log("done - image blob " + lzwblob.len())
            return true
            break;
        default:
            server.log( "unknown block - messed up " + blocktype + " " + image.tell() )
            return false
      }
    }
  }

}

class CodeString
{
    prefixIndex = 0;
    k = 0;

    constructor( newByte = 0, pI = 0){
        prefixIndex=pI;
        k=newByte;
    }
};

class LZW
{
    table = null
    encoded = null
    decoded = null
    _numsymbols = 0
    _encodedBitIndex = 0
    _currentBits = 0
    _decodedBitIndex = 0
    _decodedsize = 0
    _decodedbuffer = 0
    _decodedbuffersize = 0
    
    constructor( encodedblob, codesize, outputbits )
    {
        encoded = encodedblob
        decoded = blob()
        table = array(0)
        _numsymbols = codesize
        _decodedsize = outputbits
        server.log( "constructor " + _numsymbols + " " + _decodedsize )
    }

    function decode()
    {
        _initialize()
        local codestart = math.pow(2, _numsymbols);
        local eoiCode = codestart + 1;
        local first = _getCode()
        server.log( "first" + first + " start " + codestart)
        local oldcode = _getCode()
        _emitCode(oldcode)
        //local stopafter = 100
        while(true)
        {
            //if (stopafter-- == 0) return
            local code = _getCode()
            if ( code == eoiCode ) {
                _emitLastSymbol()
                server.log("done")
                break;
            }
            else if ( code == codestart ) {
                server.log("start symbol")
                _initialize()
            }
            else
            {
                local char
                if ( code >= table.len() ) {
                    if ( code > table.len() ) {
                        server.log("code not in table " + code + " " + table.len())
                        return
                    }
                    char = _emitCode(oldcode)
                    _emitSymbol(char)
                }
                else {
                    char = _emitCode(code)
                }
                table.append(CodeString(char, oldcode))
                _currentBits = _requiredBits(table.len());
                //server.log("oldcode " + oldcode + " newcode " + code + " bits " + _currentBits)
                oldcode = code
            }
        }
    }
    
    function _initialize(){
        table = null
        local tablesize = math.pow(2, _numsymbols) + 2
        table = array(tablesize)
        server.log("initializing code table size " + tablesize )
        _currentBits = _numsymbols + 1
        for ( local i = 0; i < tablesize; i++){
            table[i]=CodeString(i, -1)
        }
    }
    function _emitCode(code)
    {
        if ( code == -1){
            server.log("emit -1")
            return 0
        }
        local char
        if ( table[code].prefixIndex == -1){
            char = table[code].k
        }
        else {
            char = _emitCode(table[code].prefixIndex)
        }
        _emitSymbol(table[code].k)
        return char
    }
    
    function _emitSymbol(k) {
        _decodedbuffer = _decodedbuffer + (k << _decodedbuffersize)
        _decodedbuffersize += _decodedsize
        //server.log( "emit " + k + " " + format("%x", _decodedbuffer) + " " + _decodedbuffersize)
        if (_decodedbuffersize >= 8) {
            decoded.writen(_decodedbuffer, 'b' )
//            server.log("wrote buffer " + (_decodedbuffer & 0xFF) + " size " + _decodedbuffersize + " " + decoded.tell())
            _decodedbuffer = _decodedbuffer >> 8
            //server.log("new buffer " + format("%x", _decodedbuffer))
            _decodedbuffersize -= 8
        }
    }
    
    function _emitLastSymbol() {
        if (_decodedbuffersize > 0) {
            server.log("wrote buffer" + _decodedbuffer )
            decoded.writen(_decodedbuffer, 'w' )
        }
    }

    function _getCode(){
        try {
            local bitmask = 0
            for (local i = 0; i < _currentBits; i ++) {
                bitmask = (bitmask << 1) + 1
            }
            encoded.seek(_encodedBitIndex/8, 'b')
            local rawcode = 0
            if ( encoded.len() - encoded.tell() == 1) {
                server.log("last byte")
                rawcode = encoded.readn('b')
            }
            else if ( encoded.len() - encoded.tell() < 4) {
                server.log("read w")
                rawcode = encoded.readn('w')
            }
            else {
                rawcode = encoded.readn('i')
            }
            
            local code = rawcode >> (_encodedBitIndex % 8)
            code = code & bitmask
            //server.log( "code " + code + " raw " + format("%x", rawcode ) + " shifted " + format("%x", rawcode >> (_encodedBitIndex % 8)) + " bits " + _currentBits + " at " + _encodedBitIndex + " byte " + encoded.tell() + " mask " + bitmask + " len " + table.len())
            _encodedBitIndex += _currentBits
            return code
        }
        catch (exp) {
            server.log(exp)
            throw(exp)
        }
    }

    function _requiredBits(value)
    {
        local bits = 0
        while(value > 0){
           value = value >> 1
           ++bits;
        }
        return bits;
    }

}

local printerconnected=false

local settings = server.load()

function initsettings(){
    server.log("initializing settings")
    settings.deviceid <- imp.configparams.deviceid
    settings.transaction <- 0
    settings.tokenauth <- "SVo0RDhVZHZEb1hQQVBtTzRhRTJlQTAxTVZJUVdVeXg6c2NQc3ZrSnlpN0ROc3RlbQ="
    settings.accesstoken <- ""
    settings.shipperid <- "9015151412"
    settings.apiserver <- "api-sandbox.pitneybowes.com"
    settings.button <- array(3)
    settings.button[0] = 1.0
    settings.button[1] = 2.0
    settings.button[2] = 3.5
}

if (settings.len() == 0) {
    initsettings()
    server.save(settings)
}
else {
    settings.accesstoken <- ""
    server.log("loaded settings")
}

function buttonpress(data)
{
    server.log("Button " + data + " pressed ....")
    local button = data.tointeger()
    stamprequest(settings.button[button])
}

function stamprequest(weight){
    
    if ( settings.accesstoken == "" ){
        server.log( "Not authenticated" )
        led.status(notify.FLASH, notify.NO_CHANGE, notify.NO_CHANGE)
        return "Not authenticated";
    }
    led.status(notify.NO_CHANGE, notify.FLASH, notify.NO_CHANGE)
    local headers = {}
    headers["Content-Type"] <- "application/json; charset=UTF-8"
    headers["Accept-Language"] <- "en-US"
    headers["User-Agent"] <- "Pitney Bowes Imp Agent"
    headers["Authorization"] <- "Bearer " + settings.accesstoken
    headers["x-pb-transactionid"] <- settings.deviceid + format("%06u", settings.transaction++)
    server.log("Transaction ID " + headers["x-pb-transactionid"])
    local body = @"{
    ""fromAddress"" : {
        ""postalCode"" : ""06484"",
        ""countryCode"" : ""US""
    },
    ""toAddress"" : {
        ""postalCode"" : ""06484"",
        ""countryCode"" : ""US""
    },
    ""parcelWeight"" : {
        ""unitOfMeasurement"" : ""OZ"",
        ""weight"" : " + weight.tostring() + @"
    },
    ""rate"" : {
        ""carrier"" : ""usps"",
        ""serviceId"" : ""FCM"",
        ""parcelType"" : ""LTR""
    },
    ""documents"" : [
        {
            ""type"" : ""STAMP"",
            ""contentType"" : ""URL"",
            ""fileFormat"" : ""GIF""
        }
    ],
    ""stampOptions"" : [
        {
            ""name"" : ""SHIPPER_ID"",
            ""value"" : """ + settings.shipperid + @"""
        },
        {
            ""name"" : ""POSTAGE_CORRECTION"",
            ""value"" : ""false""
        }
    ]
}"
    //server.log(body)
    server.save(settings)

    local request = http.post("https://" + settings.apiserver + "/shippingservices/v1/stamps", headers, body);
    local response = request.sendsync();
    
    if ( response.statuscode == 201 ) {
        server.log("got stamp")
        server.log("Code: " + response.statuscode + ". Message: " + response.body);

        result <- JSONParser.parse(response.body)
        server.log( result.documents[0].contents )
        local request = http.get(result.documents[0].contents, headers);
        local response = request.sendsync();
        if ( response.statuscode == 200 ) {
            server.log("got stamp image")
            local imageBlob = blob()
            imageBlob.writestring(response.body)
            server.log("blobby blob " + imageBlob.len())
            local gif = GIF(imageBlob)
            gif.extract()
            server.log( "GIF " + gif.width + " " + gif.height)
            local lzw = LZW( gif.lzwblob, 2, 1 )
            lzw.decode()
            
            // prepare in printer format
            local bblob = BitBlob(lzw.decoded)
            local printimage = blob( 90 * gif.height)
            local rightpad = (375 - gif.width)/2/8 - 1// center the image to nearest byte boundary (300dpi - right margin - image width)
            server.log("padding " + rightpad)
            local pass = 0
            local row = 0
            for( local i=0 ; i < gif.height; i++) {
                //server.log( " i " + i + "," + pass +  "," + row)
                local column = 0
                for ( local j = 0; j < 90; j++ ) {
                    local byte = 0
                    if ( j > rightpad  && column < gif.width ) {
                        for ( local k = 7; k >= 0; k-- ) {
                            if (column == gif.width ) {
                                break
                            }
                            local bit = bblob.bit(i*(gif.width) + column)
                            bit = (bit == 0? 1 : 0);
                            byte = byte | (bit << k)
                            column ++
                        }
                    }
                    printimage[(gif.height - 1 - row)*90 + j] = byte
                }
                while(true) { // GIF interlacing
                    switch (pass)
                    {
                        case 0:
                            row += 8
                            break;
                        case 1:
                            if (row == 0) {
                                row = 4;
                            }
                            else {
                                row += 8
                            }
    
                            break;
                        case 2:
                            if (row == 0) {
                                row = 2;
                            }
                            else {
                                row += 4
                            }
                            break;
                        case 3: 
                            if ( row == 0 ) {
                                row = 1
                            }
                            else {
                                row += 2
                            }
                            break;
                    }
                    if ( row >= gif.height )
                    {
                        pass ++;
                        row = 0
                    }
                    else {
                        break
                    }
                }
            }
//            for ( local i = 0 ; i < gif.height ; i++ ) {
//                local line = printimage.readstring(90)
//                server.log( line )
//            }
            device.send("image", printimage)
            led.pop()
            return "Printed"   
        }
        
    }
    else {
       server.log("Code: " + response.statuscode + ". Message: " + response.body);
       local r = split(response.body, ",")
       foreach( s in r ) {
           server.log(s.slice(1, 8))
           if ( s.slice(1, 8) == "message") {
               local t = split(s, ":")
               led.pop()
               return t[1]
           }
       }   
       led.pop()
       return "Unknown service call error"
    }
    led.pop()

}

function authenticate(){
    local headers = {}
    headers["Content-Type"] <- "application/x-www-form-urlencoded"
    headers["Accept"] <- "application/json"
    headers["User-Agent"] <- "Pitney Bowes Imp Agent"
    headers["Authorization"] <- "Basic " + settings.tokenauth

    local body = "grant_type=client_credentials"
    
    local request = http.post("https://" + settings.apiserver + "/oauth/token", headers, body);
    local response = request.sendsync();
    
    if ( response.statuscode == 200 ) {
        server.log("authenticated")
        result <- JSONParser.parse(response.body)
        settings.accesstoken = result.access_token
        server.log(result.access_token)
        imp.wakeup(30000, authenticate)
    }
    else {
       server.log("Code: " + response.statuscode + ". Message: " + response.body);
       settings.accesstoken = ""
       imp.wakeup(60, authenticate)
    }
}

function settingsBody(fullpath, message) {
    local disabled = ""
    if (!printerconnected) {
        disabled = "disabled"
    }
    local b = @"
<!DOCTYPE html>
<html>
<!-- Required meta tags -->
<meta charset=""utf-8"">
<meta name=""viewport"" content=""width=device-width, initial-scale=1, shrink-to-fit=no"">
<title>CSD1 In the Cloud</title>
<link rel=""stylesheet"" href=""https://maxcdn.bootstrapcdn.com/bootstrap/4.0.0/css/bootstrap.min.css"" integrity=""sha384-Gn5384xqQ1aoWXA+058RXPxPg6fy4IWvTNh0E263XmFcJlSAwiGgFAW/dAiS6JXm"" crossorigin=""anonymous"">
<body>
<div class=""container-fluid"">
<h1>CSD1 in the cloud</h1>
<div class=""alert alert-primary"" role=""alert"">
  Device Id:"+ imp.configparams.deviceid +@"
</div>
<div class=""alert alert-success"" role=""alert"">"+ message +@"</div>
<h2>Print a stamp</h2>
<div class=""container"">
  <div class=""row"">
    <div class=""col-sm"">
        <div class=""card"" style=""width: 18rem;"">
          <div class=""card-body"">
            <h5 class=""card-title"">Button 1</h5>
                <form action=" + fullpath +@">
                  <div class=""form-group"">
                    <label for=""weight1"">Weight</label>
                    <input type=""text"" class=""form-control"" id=""weight1"" aria-describedby=""weight1Help"" placeholder=""1.0"" name=""weight1"" value= " + format("%0.2f", settings.button[0]) +@">
                    <small id=""weight1Help"" class=""form-text text-muted"">Weight for Button 1</small>
                  </div>
                  <button type=""submit"" name=""update"" class=""btn btn-primary"">Update</button>
                  <button type=""submit"" name=""print"" class=""btn btn-primary""" +  disabled
                  +@">Push Button</button>
                </form>
          </div>
        </div>
    </div>
    <div class=""col-sm"">
        <div class=""card"" style=""width: 18rem;"">
          <div class=""card-body"">
            <h5 class=""card-title"">Button 2</h5>
                <form action=" + fullpath +@">
                  <div class=""form-group"">
                    <label for=""weight2"">Weight</label>
                    <input type=""text"" class=""form-control"" id=""weight2"" aria-describedby=""weight2Help"" placeholder=""1.0"" name=""weight2"" value= " + format("%0.2f", settings.button[1]) +@">
                    <small id=""weight2Help"" class=""form-text text-muted"">Weight for Button 2</small>
                  </div>
                  <button type=""submit"" name=""update"" class=""btn btn-primary"">Update</button>
                  <button type=""submit"" name=""print"" class=""btn btn-primary""" + disabled
                  +@">Push Button</button>
                </form>
          </div>
        </div>
    </div>
    <div class=""col-sm"">
        <div class=""card"" style=""width: 18rem;"">
          <div class=""card-body"">
            <h5 class=""card-title"">Button 3</h5>
                <form action=" + fullpath +@">
                  <div class=""form-group"">
                    <label for=""weight3"">Weight</label>
                    <input type=""text"" class=""form-control"" id=""weight3"" aria-describedby=""weight3Help"" placeholder=""1.0"" name=""weight3"" value= " + format("%0.2f", settings.button[2]) +@">
                    <small id=""weight3Help"" class=""form-text text-muted"">Weight for Button 3</small>
                  </div>
                  <button type=""submit"" name=""update"" class=""btn btn-primary"">Update</button>
                  <button type=""submit"" name=""print"" class=""btn btn-primary""" + disabled
                  +@">Push Button</button>
                </form>
          </div>
        </div>
    </div>
    <div class=""col-sm"">
        <div class=""card"" style=""width: 18rem;"">
          <div class=""card-body"">
            <h5 class=""card-title"">Custom Postage</h5>
                <form action=" + fullpath +@">
                  <div class=""form-group"">
                    <label for=""weightcustom"">Weight</label>
                    <input type=""text"" class=""form-control"" id=""weightcustom"" aria-describedby=""weightcustomHelp"" placeholder=""1.0"" name=""weightcustom"" >
                    <small id=""weightcustomHelp"" class=""form-text text-muted"">Weight for postage</small>
                  </div>
                  <button type=""submit"" name=""print"" class=""btn btn-primary""" + disabled
                  +@">Print</button>
                </form>
          </div>
        </div>
    </div>
  </div>
</div>
<h2>Settings</h2>
<form action=" + fullpath +@">
  <div class=""form-group"">
    <label for=""transactionSequence"">Transaction Sequence</label>
    <input type=""text"" class=""form-control"" id=""transactionSequence"" aria-describedby=""reansactionHelp"" placeholder=""Sequence Number"" name=""transaction"" value="+ settings.transaction +@">
    <small id=""reansactionHelp"" class=""form-text text-muted"">Sequence number to generate unique transaction ID.</small>
  </div>
  <div class=""form-group"">
    <label for=""shipperID"">Shipper ID</label>
    <input type=""text"" class=""form-control"" id=""shipperID"" aria-describedby=""shipperHelp"" placeholder=""Shipper ID"" name=""shipperid"" value="+ settings.shipperid +@">
    <small id=""shipperHelp"" class=""form-text text-muted"">Shipper ID.</small>
  </div>
  <div class=""form-group"">
    <label for=""tokenAuth"">Token auth string</label>
    <input type=""password"" class=""form-control"" id=""tokenAuth"" placeholder=""Password"" name=""tokenauth"" value="+ settings.tokenauth +@">
  </div>
  <button type=""submit"" name=""update"" class=""btn btn-primary"">Submit</button>
</div>
<script src=""https://code.jquery.com/jquery-3.2.1.slim.min.js"" integrity=""sha384-KJ3o2DKtIkvYIK3UENzmM7KCkRr/rE9/Qpg6aAZGJwFDMVNA/GpGFF93hXpG5KkN"" crossorigin=""anonymous""></script>
<script src=""https://cdnjs.cloudflare.com/ajax/libs/popper.js/1.12.9/umd/popper.min.js"" integrity=""sha384-ApNbgh9B+Y1QKtv3Rn7W3mgPxhU9K/ScQsAP7hUibX39j7fakFPskvXusvfa0b4Q"" crossorigin=""anonymous""></script>
<script src=""https://maxcdn.bootstrapcdn.com/bootstrap/4.0.0/js/bootstrap.min.js"" integrity=""sha384-JZR6Spejh4U02d8jOt6vLEHfe/JQGiRRSQQxSfFWpi1MquVdAyjUar5+76PVCmYl"" crossorigin=""anonymous""></script>
<script type=""text/javascript"">
function load()
{
setTimeout(""location.href = '" + fullpath + @"';"", 15000);
}
</script>
<body onload=""load()"">
</body>
</html>"
    //server.log(b)
    return b
}

function requestHandler(request, response) {
    server.log("Request " + request.path + " " + request.method)
    try {  
        local auth = ""
        foreach( key, value in request.headers) {
            if ( key.tolower() == "authorization") {
                auth = value
                break
            }
        }
        if (auth == "") {
            response.header("WWW-Authenticate",@"Basic realm=""Access to PB Junior Imp""")
            response.send( 401, "Not authorized")
            server.log("Not authorized")
            return
        }
        if ( request.path == "/settings" ){
            local fullpath = http.agenturl() + "/settings"
            if (request.method == "GET") {
                local body = settingsBody(fullpath, "")
                if ( "update" in request.query ) {
                    if ("tokenauth" in request.query) {
                        settings.tokenauth = request.query.tokenauth
                        return
                    }
                    if ("transaction" in request.query) {
                        settings.transaction = request.query.transaction
                        return
                    }                
                    if ("shipperid" in request.query) {
                        settings.shipperid = request.query.shipperid
                        return
                    }
                    if ("weight1" in request.query) {
                        settings.button[0] = request.query.weight1.tofloat();
                    }
                    if ("weight2" in request.query) {
                        settings.button[1] = request.query.weight2.tofloat();
                    }
                    if ("weight3" in request.query) {
                        server.log("setting button 3" + request.query.weight3)
                        settings.button[2] = request.query.weight3.tofloat();
                    }
                    server.log("saving")
                    server.log("button 2 " + settings.button[2])
                    server.save(settings)
                    response.send( 200, settingsBody(fullpath, "Saved"))
                    return
                }
                else  if ( printerconnected && "print" in request.query ) {
                    local weight=0.0
                    if ("weight1" in request.query) {
                        weight = settings.button[0];
                    }
                    if ("weight2" in request.query) {
                        weight = settings.button[1];
                    }
                    if ("weight3" in request.query) {
                        weight = settings.button[2];
                    }
                    if ("weightcustom" in request.query) {
                        weight = request.query.weightcustom.tofloat();
                    }
                    local m = stamprequest(weight)
                    response.send(200, settingsBody(fullpath, m ))
                    return
                }
                local m = "Printer disconnected"
                if (printerconnected) m = "Printer connected"
                response.send( 200, settingsBody(fullpath, m))
                return
            }
        }
        response.send( 400, "Page not found")
    } catch (exp) {
        server.log(exp)
        response.send(500, "Error");
    }
}

device.on( "startup", function(value) {
    server.log("Agent URL " + http.agenturl() )
    led.status(notify.OFF, notify.ON, notify.OFF)
    authenticate()
});

//server.log("here")
device.on("button", buttonpress)

http.onrequest(requestHandler)

device.on( "printer", function(value) {
    server.log("Printer event " + value )
    if ( value == "connect" ) {
        printerconnected = true
        led.status(notify.NO_CHANGE, notify.NO_CHANGE, notify.ON)
    }
    if ( value == "disconnect" ) {
        printerconnected=false
        led.status(notify.NO_CHANGE, notify.NO_CHANGE, notify.OFF)
    }
    if ( value == "unknown" ) {
        printerconnected=false
        led.status(notify.NO_CHANGE, notify.NO_CHANGE, notify.FLASH)
    }
});

device.on( "printerstatus", function(value) {
    local status = PrinterStatus(value)
    local statustype = status.statustype()
    if ( statustype == PrinterStatus.STATUS_REQUEST_REPLY ) {
        server.log("Request response")        
    }
    else if ( statustype == PrinterStatus.STATUS_PRINT_COMPLETE ) {
        server.log("Print complete")
    } 
    else if ( statustype == PrinterStatus.STATUS_ERROR ) {
        server.log("Error")
    } 
    else if ( statustype == PrinterStatus.STATUS_NOTIFY ) {
        server.log("notify")
    } 
    else if ( statustype == PrinterStatus.STATUS_PHASE_CHANGE ) {
        server.log("Phase change")
        led.status(notify.NO_CHANGE, notify.ON, notify.NO_CHANGE)
    } 
    if ( status.error() == PrinterStatus.ERROR_NONE ) {
        server.log("Non error status packet received")
    }
    else {
        server.log("Error packet received")
    }
});

