# debug = (args...) -> console.log.apply(console, args)
debug = (args...) -> return

makeDelegatingCallbackFn = (cachedSub, callbackName)->
  # console.log("SC makeDelegatingCallbackFn", this, arguments);
  ->
    originalThis = @
    originalArgs = arguments
    _.each cachedSub.callbacks, (cbs)->
      if _.isFunction cbs[callbackName]
        cbs[callbackName].apply originalThis, originalArgs

hasCallbacks = (args)->
  # console.log("SC hasCallbacks", this, arguments);
  # this logic is copied from Meteor.subscribe found in
  # https://github.com/meteor/meteor/blob/master/packages/ddp/livedata_connection.js
  if args.length
    lastArg = args[args.length-1]
    _.isFunction(lastArg) or
      (lastArg and _.any([
        lastArg.onReady,
        lastArg.onError,
        lastArg.onStop
      ], _.isFunction))

withoutCallbacks = (args)->
  # console.log("SC withoutCallbacks", this, arguments);
  if hasCallbacks args
    args[..-1]
  else
    args[..]

callbacksFromArgs = (args)->
  # console.log("SC callbacksFromArgs", this, arguments);
  if hasCallbacks args
    if _.isFunction args[args.length-1]
      onReady: args[args.length-1]
    else
      args[args.length-1]
  else
    {}

class @SubsCache
  @caches: []

  constructor: (obj) ->
    console.log("SC constructor", this, arguments);
    expireAfter = undefined
    cacheLimit = undefined
    if obj
      {expireAfter, cacheLimit} = obj

    # defaults
    if expireAfter is undefined
      expireAfter = 5
    if cacheLimit is undefined
      cacheLimit = 10
    # catch an odd error
    if cacheLimit is 0
      console.warn "cacheLimit cannot be zero!"
      cacheLimit = 1

    # initialize instance variables
    @expireAfter = expireAfter
    @cacheLimit = cacheLimit
    @cache = {}
    @allReady = new ReactiveVar(true)
    SubsCache.caches.push(@)

  ready: ->
    console.log("SC ready", this, arguments);
    @allReady.get()

  onReady: (callback) ->
    console.log("SC OnReady", this, arguments);
    Tracker.autorun (c) =>
      if @ready()
        c.stop()
        callback()

  @clearAll: ->
    console.log("SC clearAll", this, arguments);
    @caches.map (s) -> s.clear()

  clear: ->
    console.log("SC clear", this, arguments);
    _.values(@cache).map((sub)-> sub.stopNow())

  subscribe: (args...) ->
    console.log("SC subscribe", this, arguments);
    args.unshift(@expireAfter)
    @subscribeFor.apply(this, args)

  subscribeFor: (expireTime, args...) ->
    console.log("SC subscribeFor", this, arguments);
    if Meteor.isServer
      # If we're using fast-render for SSR
      Meteor.subscribe.apply(Meteor.args)
    else
      hash = EJSON.stringify(withoutCallbacks args)
      cache = @cache
      if hash of cache
        # if we find this subscription in the cache, then rescue the callbacks
        # and restart the cached subscription
        if hasCallbacks args
          cache[hash].registerCallbacks callbacksFromArgs args
        cache[hash].restart()
      else
        # create an object to represent this subscription in the cache
        cachedSub =
          sub: null
          hash: hash
          timerId: null
          expireTime: expireTime
          when: null
          callbacks: []
          ready: ->
            console.log("SC 2 ready", this, arguments);
            @sub.ready()
          onReady: (callback)->
            console.log("SC 2 onReady", this, arguments);
            if @ready()
              Tracker.nonreactive -> callback()
            else
              Tracker.autorun (c) =>
                if @ready()
                  c.stop()
                  Tracker.nonreactive -> callback()
          registerCallbacks: (callbacks)->
            # console.log("SC 2 registerCallbacks", this, arguments);
            if _.isFunction callbacks.onReady
              @onReady callbacks.onReady
            @callbacks.push callbacks
          getDelegatingCallbacks: ->
            # console.log("SC 2 getDelegatingCallbacks", this, arguments);
            # make functions that delegate to all register callbacks
            onError: makeDelegatingCallbackFn @, 'onError'
            onStop: makeDelegatingCallbackFn @, 'onStop'
          start: ->
            console.log("SC 2 start", this, arguments);
            # so we know what to throw out when the cache overflows
            @when = Date.now()
            # if the computation stops, then delayedStop
            c = Tracker.currentComputation
            c?.onInvalidate =>
              @delayedStop()
            #  catch err
            #    console.info 'Warning! SubsCache ignoring exception:', err.message
          stop: ->
            console.log("SC 2 stop", this, arguments);
            @delayedStop()
          delayedStop: ->
            console.log("SC 2 delayedStop", this, arguments);
            if expireTime >= 0
              @timerId = setTimeout(@stopNow.bind(this), expireTime*1000*60)
          restart: ->
            console.log("SC 2 restart", this, arguments);
            # if we'are restarting, then stop the timer
            clearTimeout(@timerId)
            @start()
          stopNow: ->
            console.log("SC 2 stopNow", this, arguments);
            @sub.stop()
            delete cache[@hash]

        # create the subscription, giving it delegating callbacks
        newArgs = withoutCallbacks args
        newArgs.push cachedSub.getDelegatingCallbacks()
        # make sure the subscription won't be stopped if we are in a reactive computation
        cachedSub.sub = Tracker.nonreactive -> Meteor.subscribe.apply(Meteor, newArgs)

        if hasCallbacks args
          cachedSub.registerCallbacks callbacksFromArgs args

        # delete the oldest subscription if the cache has overflown
        if @cacheLimit > 0
          allSubs = _.sortBy(_.values(cache), (x) -> x.when)
          numSubs = allSubs.length
          if numSubs >= @cacheLimit
            needToDelete = numSubs - @cacheLimit + 1
            for i in [0...needToDelete]
              debug "overflow", allSubs[i]
              allSubs[i].stopNow()



        cache[hash] = cachedSub
        cachedSub.start()

        # reactively set the allReady reactive variable
        @allReadyComp?.stop()
        Tracker.autorun (c) =>
          @allReadyComp = c
          subs = _.values(@cache)
          if subs.length > 0
            @allReady.set subs.map((x) -> x.ready()).reduce((a,b) -> a and b)

      return cache[hash]
