
var fs = require("fs")
var Web3 = require('web3')
var web3 = new Web3()

var dir = "./compiled/"

var code = "0x" + fs.readFileSync(dir + "Scrypt.bin")
var abi = JSON.parse(fs.readFileSync(dir + "Scrypt.abi"))

var config = JSON.parse(fs.readFileSync("/home/sami/webasm-solidity/node/config.json"))

var host = config.host

var send_opt = {gas:4700000, from:config.base}

var w3provider = new web3.providers.WebsocketProvider('ws://' + host + ':8546')
web3.setProvider(w3provider)

var filesystem = new web3.eth.Contract(JSON.parse(fs.readFileSync("/home/sami/webasm-solidity/contracts/compiled/Filesystem.abi")), config.fs)

function arrange(arr) {
    var res = []
    var acc = ""
    arr.forEach(function (b) { acc += b; if (acc.length == 64) { res.push("0x"+acc); acc = "" } })
    if (acc != "") res.push("0x"+acc)
    console.log(res)
    return res
}

async function createFile(fname, buf) {
    var nonce = await web3.eth.getTransactionCount(config.base)
    var arr = []
    for (var i = 0; i < buf.length; i++) {
        if (buf[i] > 15) arr.push(buf[i].toString(16))
        else arr.push("0" + buf[i].toString(16))
    }
    console.log("Nonce", nonce, {arr:arrange(arr)})
    var tx = await filesystem.methods.createFileWithContents(fname, nonce, arrange(arr), buf.length).send(send_opt)
    var id = await filesystem.methods.calcId(nonce).call(send_opt)
    return id
}

async function outputFile(id) {
    var lst = await filesystem.methods.getData(id).call(send_opt)
    console.log("File data for", id, "is", lst)
    var dta = await filesystem.methods.debug_forwardData(id, config.coindrop).call(send_opt)
    console.log("DEBUG: ", dta)
}

/*
function stringToBytes(str) {
    var lst = []
    for (var i = 0; i < str.length; i++) {
        lst.push(str.charCodeAt(i))
    }
    return lst
}*/

function stringToBytes(str) {
    var lst = Buffer.from(str)
    return "0x" + lst.toString("hex")
}

async function doDeploy() {
    var send_opt = {gas:4700000, from:config.base}
//    console.log(send_opt, file_id)
    var init_hash = "0xaaa81417bc9a75a6623f9da64bf9ce8496be62d2d6d2d3aa179b46d2a93cc085"
    var code_address = "QmcCieydTJPMANAyqH92LTYcobvzkiq9YPZs82yhU81WKm"
    var contract = await new web3.eth.Contract(abi).deploy({data: code, arguments:[config.tasks, config.fs, code_address, init_hash]}).send(send_opt)
    config.scrypt = contract.options.address
    console.log(JSON.stringify(config))
    contract.setProvider(w3provider)
    contract.events.InputData(function (err,ev) {
        if (err) return console.log(err)
        console.log("Input data", ev.returnValues)
    })
    // await contract.methods.submitData(stringToBytes("heihei\n")).send(send_opt)
    console.log("Bytes", stringToBytes("heihei\n"))
    var tx = await contract.methods.submitData(stringToBytes("heihei\n")).send(send_opt)
    console.log(tx)
    contract.events.GotFiles(function (err,ev) {
        if (err) return console.log(err)
        console.log("Files", ev.returnValues)
        var files = ev.returnValues.files
        files.forEach(outputFile)
    })
    contract.events.Consuming(function (err,ev) {
        if (err) return console.log(err)
        console.log("Consuming", ev.returnValues)
    })
    // process.exit(0)
}

doDeploy()

