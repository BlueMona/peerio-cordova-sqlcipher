do ->
  root = @

  SQLitePlugin = (openargs, openSuccess, openError) ->
    console.log "SQLitePlugin"

    if !(openargs and openargs['name'])
      throw new Error("Cannot create a SQLitePlugin instance without a db name")

    dbname = openargs.name

    @openargs = openargs
    @dbname = dbname

    @openSuccess = openSuccess
    @openError = openError

    @openSuccess or
      @openSuccess = ->
        console.log "DB opened: " + dbname

    @openError or
      @openError = (e) ->
        console.log e.message

    @open @openSuccess, @openError
    return

  SQLitePlugin::databaseFeatures = isSQLitePluginDatabase: true
  SQLitePlugin::openDBs = {}

  SQLitePlugin::txQ = []

  SQLitePlugin::transaction = (fn, error, success) ->
    t = new SQLitePluginTransaction(this, fn, error, success)
    @txQ.push t
    if @txQ.length is 1
      t.start()
    return

  SQLitePlugin::startNextTransaction = ->
    @txQ.shift()
    if @txQ[0]
      @txQ[0].start()
    return

  SQLitePlugin::open = (success, error) ->
    console.log "SQLitePlugin.prototype.open"

    unless @dbname of @openDBs
      @openDBs[@dbname] = true
      cordova.exec success, error, "SQLitePlugin", "open", [ @openargs ]

    return

  # FUTURE (??):
  #SQLitePlugin::close = (success, error) ->
  #  console.log "SQLitePlugin.prototype.close"
  #  ..
  #  return

  # TBD (TODO) add implementation:
  #SQLitePlugin::executeSql = (statement, params, success, error) ->
  #  ..
  #  return

  uid = 1000

  get_unique_id = -> ++uid

  trcbq = {}

  SQLitePluginTransaction = (db, fn, error, success) ->
    @trid = get_unique_id()
    trcbq[@trid] = {}
    if typeof(fn) != "function"
      # This is consistent with the implementation in Chrome -- it
      # throws if you pass anything other than a function. This also
      # prevents us from stalling our txQueue if somebody passes a
      # false value for fn.
      throw new Error("transaction expected a function")
    @db = db
    @fn = fn
    @error = error
    @success = success
    @executes = []
    @executeSql "BEGIN", [], null, (tx, err) ->
      throw new Error("unable to begin transaction: " + err.message)
    return

  SQLiteTransactionCB =
    batchCompleteCallback: (cbResult) ->
      console.log "SQLiteTransactionCB.batchCompleteCallback cbResult #{JSON.stringify cbResult}"

      trid = cbResult.trid
      result = cbResult.result

      for r in result
        type = r.type
        qid = r.qid
        res = r.result

        t = trcbq[trid]

        if t
          q = t[qid]

          if q
            if q[type]
              q[type] res

            # ???:
            delete trcbq[trid][qid]

      return

  SQLitePluginTransaction::start = ->
    try
      return  unless @fn
      @fn this
      @fn = null
      @run()
    catch err
      # If "fn" throws, we must report the whole transaction as failed.
      @db.startNextTransaction()
      if @error
        @error err
    return

  SQLitePluginTransaction::executeSql = (sql, values, success, error) ->
    #console.log "SQLitePluginTransaction::executeSql"
    qid = get_unique_id()

    @executes.push
      #query: [sql].concat(values or [])
      success: success
      error: error
      qid: qid

      sql: sql
      params: values

    return

  SQLitePluginTransaction::handleStatementSuccess = (handler, response) ->
    if !handler
      return

    rows = response.rows || []
    payload =
      rows:
        item: (i) ->
          rows[i]

        length: rows.length

      rowsAffected: response.rowsAffected or 0
      insertId: response.insertId or undefined

    handler this, payload

    return

  SQLitePluginTransaction::handleStatementFailure = (handler, response) ->
    if !handler
      throw new Error "a statement with no error handler failed: " + response.message
    if handler(this, response)
      throw new Error "a statement error callback did not return false"
    return

  SQLitePluginTransaction::run = ->
    #console.log "SQLitePluginTransaction::run"
    txFailure = null

    tropts = []
    batchExecutes = @executes
    waiting = batchExecutes.length
    @executes = []
    tx = this

    # TBD ???:
    #batchid = get_unique_id()

    handlerFor = (index, didSucceed) ->
      (response) ->
        try
          if didSucceed
            tx.handleStatementSuccess batchExecutes[index].success, response
          else
            tx.handleStatementFailure batchExecutes[index].error, response
        catch err
          txFailure = err  unless txFailure

        if --waiting == 0
          if txFailure
            tx.rollBack txFailure
          else if tx.executes.length > 0
            # new requests have been issued by the callback
            # handlers, so run another batch.
            tx.run()
          else
            tx.commit()

    i = 0

    while i < batchExecutes.length
      request = batchExecutes[i]

      qid = request.qid

      trcbq[@trid][qid] =
        success: handlerFor(i, true)
        error: handlerFor(i, false)

      tropts.push
        qid: qid
        # for ios version:
        query: [request.sql].concat(request.params)
        # XXX trans_id going away:
        trans_id: @trid
        sql: request.sql
        params: request.params || []

      i++

    # XXX TODO fix command Android/iOS/WP(8):
    cordova.exec null, null, "SQLitePlugin", "executeBatchTransaction", [ {dbargs: {dbname: @db.dbname}, executes: tropts} ]
    return

  SQLitePluginTransaction::rollBack = (txFailure) ->
    if @finalized then return
    tx = @

    succeeded = ->
      delete trcbq[@trid]
      tx.db.startNextTransaction()
      if tx.error then tx.error txFailure

    failed = (tx, err) ->
      delete trcbq[@trid]
      tx.db.startNextTransaction()
      if tx.error then tx.error new Error("error while trying to roll back: " + err.message)

    @finalized = true
    @executeSql "ROLLBACK", [], succeeded, failed
    @run()
    return

  SQLitePluginTransaction::commit = ->
    if @finalized then return
    tx = @

    succeeded = ->
      delete trcbq[@trid]
      tx.db.startNextTransaction()
      if tx.success then tx.success()

    failed = (tx, err) ->
      delete trcbq[@trid]
      tx.db.startNextTransaction()
      if tx.error then tx.error new Error("error while trying to commit: " + err.message)

    @finalized = true
    @executeSql "COMMIT", [], succeeded, failed
    @run()
    return

  SQLiteFactory =
    # NOTE: this function should NOT be translated from Javascript
    # back to CoffeeScript by js2coffee.
    # If this function is edited in Javascript then someone will
    # have to translate it back to CoffeeScript by hand.
    opendb: ->
      if arguments.length < 1 then return null

      first = arguments[0]
      openargs = null
      okcb = null
      errorcb = null

      if first.constructor == String
        openargs = {name: first}

        if arguments.length >= 5
          okcb = arguments[4]
          if arguments.length > 5 then errorcb = arguments[5]

      else
        openargs = first

        if arguments.length >= 2
          okcb = arguments[1]
          if arguments.length > 2 then errorcb = arguments[2]

      new SQLitePlugin openargs, okcb, errorcb

  # required for callbacks (TBD going away):
  root.SQLiteTransactionCB = SQLiteTransactionCB

  root.sqlitePlugin =
    sqliteFeatures:
      isSQLitePlugin: true

    openDatabase: SQLiteFactory.opendb

