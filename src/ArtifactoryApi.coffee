###
  The MIT License (MIT)

  Copyright (c) 2015 Christian Adam, Justin Murray

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
  copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  SOFTWARE.
###

Q = require('q')
request = require('request')
path = require('path')
fs = require('fs')
md5File = require('md5-file')

class ArtifactoryApi
  v4Root = '/artifactory/'
  v3Root = '/'
  constructor: (@url, @basicHttpAuth, version=4) ->
    while @url[@url.length - 1] is '/'
      @url = @url.substr(0, @url.length - 1)
    if version < 4
      @urlRoot = "#{@url}#{v3Root}"
    else
      @urlRoot = "#{@url}#{v4Root}"
    @_request = request.defaults({
      headers:
        Authorization: 'Basic ' + @basicHttpAuth
      strictSSL: false
    })
    
  apiRoot: -> "#{@urlRoot}api/"

  _qRequest: (url, method='GET') ->
    Q.Promise (resolve, reject) =>
      opts =
        url: url
        method: method
      @_request opts, (error, resp) ->
        return reject(error.message) if error
        resolve(resp)

  _getJSON: (url) -> @_qRequest(url).then (resp) ->
    # Expect OK response
    return Q.reject(resp.statusCode) unless resp.statusCode is 200
    JSON.parse(resp.body)

  checkApiVersion: ->
    # try version 4 api first
    @_getJSON("#{@url}#{v4Root}api/system/version")
      .then (resp) =>
        @urlRoot = "#{@url}#{v4Root}"
        return resp.version
      .catch =>
        # try version 3 instead
        @_getJSON("#{@url}#{v3Root}api/system/version")
          .then (resp) =>
            @urlRoot = "#{@url}#{v3Root}"
            return resp.version

  ### Get file info from Artifactory server. The result is provided in a json object.
  @param   {string} repoKey  The key of the repo where the file is stored.
  @param   {string} remoteFilePath The path to the file inside the repo.
  @returns {object} A QPromise to a json object with the file's info as specified in the {@link http://www.jfrog.com/confluence/display/RTF/Artifactory+REST+API#ArtifactoryRESTAPI-FileInfo|FileInfo} Artifactory API.
  ###
  getFileInfo: (repoKey, remoteFilePath) ->
    remoteFilePath = remoteFilePath.substr(1) while remoteFilePath[0] is '/'
    @_getJSON("#{@apiRoot()}storage/#{repoKey}/#{remoteFilePath}")

  ###
  Checks if the file exists.
  @param   {string} repoKey  The key of the repo where the file is stored.
  @param   {string} remoteFilePath The path to the file inside the repo.
  @returns {object} A QPromise to a boolean value
  ###
  fileExists: (repoKey, remoteFilePath) ->
    remoteFilePath = remoteFilePath.substr(1) while remoteFilePath[0] is '/'
    @_request("#{@apiRoot()}#{repoKey}/#{remoteFilePath}", 'head').then (resp) ->
      switch resp.statusCode
        when 200 then true
        when 404 then false
        else Q.reject(resp.statusCode)

  deleteItem: (repoKey, remoteFilePath) ->
    remoteFilePath = remoteFilePath.substr(1) while remoteFilePath[0] is '/'
    @_qRequest("#{@urlRoot}#{repoKey}/#{remoteFilePath}", 'DELETE').then (resp) ->
      # Expect 204 response
      return Q.reject(resp.statusCode) unless resp.statusCode is 204

  ###
  Uploads a file to artifactory. The uploading file needs to exist!
  @param   {string} repoKey  The key of the repo where the file is stored.
  @param   {string} remoteFilePath The path to the file inside the repo. (in the server)
  @param   {string} fileToUploadPath Absolute or relative path to the file to upload.
  @param   {boolean} [forceUpload=false] Flag indicating if the file should be upload if it already exists.
  @returns {object} A QPromise to a json object with creation info as specified in the {@link http://www.jfrog.com/confluence/display/RTF/Artifactory+REST+API#ArtifactoryRESTAPI-DeployArtifact|DeployArtifact} Artifactory API.
  ###
  uploadFile: (repoKey, remoteFilePath, fileToUploadPath, forceUpload) ->
    overwriteFileInServer = forceUpload || false
    isRemote = !!fileToUploadPath.match(/^https?:\/\//i)
    fileToUpload = isRemote ? fileToUploadPath : path.resolve(fileToUploadPath)

    # Check the file to upload does exist! (if local)
    if !isRemote && !fs.existsSync(fileToUpload)
      return Q.reject('The file to upload ' + fileToUpload + ' does not exist')

    # Check if file exists...
    return @fileExists(repoKey, remoteFilePath)
      .then (fileExists) =>
        if fileExists && !overwriteFileInServer
          return Q.reject('File already exists and forceUpload flag was not provided with a TRUE value.')

        stream = if isRemote then @_request(fileToUpload) else fs.createReadStream(fileToUpload)
        # In any other case then proceed with *upload*
        deferred = Q.defer()
        stream.pipe @_request.put "#{@apiRoot()}storage/#{repoKey}/#{remoteFilePath}", (error, response) ->
          return deferred.reject(error.message) if error
          # We expect a CREATED return code.
          unless response.statusCode is 201
            return deferred.reject('HTTP Status Code from server was: ' + response.statusCode)

          deferred.resolve(JSON.parse(response.body))
        return deferred.promise

  ### Downloads an artifactory artifact to a specified file path. The folder where the file will be created MUST exist.
  @param   {string} repoKey  The key of the repo where the file is stored.
  @param   {string} remoteFilePath The path to the file inside the repo. (in the server)
  @param   {string} destinationFile Absolute or relative path to the destination file. The folder that will contain the destination file must exist.
  @param   {boolean} [checkChecksum=false] A flag indicating if a checksum verification should be done as part of the download.
  @returns {object} A QPromise to a string containing the result.
  ###
  downloadFile: (repoKey, remoteFilePath, destinationFile, checkChecksum) ->
    checkFileIntegrity = checkChecksum || false
    destinationPath = path.resolve(destinationFile)

    unless fs.existsSync(path.dirname(destinationPath))
      return Q.reject('The destination folder ' + path.dirname(destinationPath) + ' does not exist.')

    deferred = Q.defer()
    url = "#{@apiRoot()}storage/#{repoKey}/#{remoteFilePath}"
    @_request
      .get(url)
      .on 'response', (resp) =>
        return deferred.reject("Server returned #{resp.statusCode}") unless resp.statusCode is 200
        stream = req.pipe(fs.createWriteStream(destinationPath))
        stream.on 'finish', =>
          if checkFileIntegrity
            @getFileInfo(repoKey, remoteFilePath)
              .then (fileInfo) ->
                md5File destinationPath, (err, sum) ->
                  return deferred.reject("Error while calculating MD5: #{err.toString()}") if err
                  if sum is fileInfo.checksums.md5
                    deferred.resolve("Download was SUCCESSFUL even checking expected checksum MD5 (#{fileInfo.checksums.md5})")
                  else
                    deferred.reject("Error downloading file '#{options.url}'. Checksum (MD5) validation failed. Expected: #{fileInfo.checksums.md5} - Actual downloaded: #{sum}")
              .fail (err) -> deferred.reject(err)
          else
            deferred.resolve('Download was SUCCESSFUL')
    return deferred.promise

module.exports = ArtifactoryApi
