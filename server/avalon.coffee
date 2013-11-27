#
# Server side game functions
#

Array::sum = () ->
    @reduce (x, y) -> x + y

send_game_list = () ->
    Game.find {}, (err, games) ->
        data = []
        for g in games
            if (g.state == GAME_LOBBY) then data.push
                id : g.id
                name : g.name()
                num_players : g.players.length
        io.sockets.in('lobby').emit('gamelist', data)

send_game_info = (game, to = undefined) ->
    data =
        state           : game.state
        options         : game.gameOptions
        id              : game.id
        roles           : game.roles
        currentLeader   : game.currentLeader
        currentMission  : game.currentMission
        missions        : game.missions

    #Overwrite player data (to hide secret info)
    #Split out socket ids while we're at it, no need to send them
    players = []
    socks = []
    for p, i in game.players
        if to == undefined || p.id.equals(to)
            socks.push
                socket  : io.sockets.socket(p.socket)
                player  : i
        players.push
            id          : p.id
            name        : p.name
            order       : p.order

    data.players = players

    #Hide unfinished votes
    votes = []
    for v in game.votes
        dv = {mission: v.mission, team: v.team, votes: []}
        if v.votes.length == game.players.length
            dv.votes = v.votes
        else
            dv.votes = []
            for pv in v.votes
                dv.votes.push {id: pv.id}
        votes.push dv

    data.votes = votes

    #Hide individual quest cards
    missions = []
    for m in game.missions
        numfails = 0
        for p in m.players
            if !p.success then numfails += 1
        dm = {numReq:m.numReq, failsReq: m.failsReq, status: m.status, numfails: numfails}
        missions.push dm

    data.missions = missions

    if game.state == GAME_FINISHED
        data.evilWon = game.evilWon
        data.assassinated = undefined
        for p in game.players
            if p.id.equals(game.assassinated)
                data.assassinated = p.name

    #Add in secret info specific to player as we go
    for s in socks
        i = s.player
        data.players[i].role = game.players[i].role
        data.players[i].isEvil = game.players[i].isEvil
        data.players[i].info = game.players[i].info
        data.me = data.players[i]
        s.socket.emit('gameinfo', data)
        data.players[i].role = undefined
        data.players[i].isEvil = undefined
        data.players[i].info = []

leave_game = (player_id, game_id) ->
    Game.findById game_id, (err, game) ->
        return if not game
        for p in game.players
            if p.id.equals(player_id)
                if game.state == GAME_LOBBY || game.state == GAME_PREGAME
                    index = game.players.indexOf(p)
                    game.players.splice(index, 1)
                else
                    p.left = true
                    p.socket = undefined
                break

        game.save (err, game) ->
            if game.players.length == 0
                game.remove()
            send_game_info(game)
            send_game_list()

shuffle = (a) ->
      for i in [a.length-1..1]
          j = Math.floor Math.random() * (i + 1)
          [a[i], a[j]] = [a[j], a[i]]
      return a

start_game = (game, order) ->
    game.state = GAME_PROPOSE

    game.roles.push
        name    : "Merlin"
        isEvil  : false
    game.roles.push
        name    : "Assassin"
        isEvil  : true
    game.roles.push
        name    : "Percival"
        isEvil  : false
    game.roles.push
        name    : "Morgana"
        isEvil  : true
    cur_evil = 2

    num_evil = Math.ceil(game.players.length / 3)

    if game.gameOptions.mordred && cur_evil < num_evil
        game.roles.push
            name    : "Mordred"
            isEvil  : true
        cur_evil += 1

    if game.gameOptions.oberon && cur_evil < num_evil
        game.roles.push
            name    : "Oberon"
            isEvil  : true
        cur_evil += 1

    #Fill evil
    while (cur_evil < num_evil)
        game.roles.push
            name : "Minion"
            isEvil : true
        cur_evil += 1

    #Fill good
    while (game.roles.length < game.players.length)
        game.roles.push
            name : "Servant"
            isEvil : false

    #Assign roles
    playerroles = shuffle(game.roles)
    for p, i in game.players
        r = playerroles.pop()
        p.role = r.name
        p.isEvil = r.isEvil
        if i == 0
            p.order = 0
        else
            p.order = order[p.id]

    #Sort by order
    game.players.sort((a, b) -> a.order - b.order)

    #Give info
    for p in game.players
        switch p.role
            when "Merlin", "Assassin", "Minion", "Morgana", "Mordred"
                for o in game.players
                    if o.isEvil
                        if p.role == "Merlin" && o.role == "Mordred"
                            continue
                        if p.role != "Merlin" && o.role == "Oberon"
                            continue
                        p.info.push
                            otherPlayer : o.name
                            information : "evil"
            when "Percival"
                for o in game.players
                    if o.role == "Merlin" || o.role == "Morgana"
                        p.info.push
                            otherPlayer : o.name
                            information : "magic"

    game.setup_missions()
    leader = Math.floor Math.random() * game.players.length
    game.currentLeader = game.players[leader].id

#
# Socket handling
#

io.on 'connection', (socket) ->
    socket.on 'login', (data) ->
        socket.join('lobby')
        player = new Player()
        player.name = data['name']
        player.socket = socket.id
        player.save()
        socket.set('player_id', player._id)
        socket.emit('player_id', player._id)
        send_game_list()

    socket.on 'login_cookie', (player_id) ->
        Player.findById player_id, (err, player) ->
            if not player
                socket.emit('bad_login')
                return

            player.socket = socket.id
            player.save()
            socket.set('player_id', player._id)
            Game.findById player.currentGame, (err, game) ->
                if not game
                    socket.join('lobby')
                    send_game_list()
                    return

                #Reconnect to game
                socket.set('game', game._id)
                for p in game.players
                    if p.id.equals(player_id)
                        if p.left
                            socket.emit('previous_game', game._id)
                            socket.join('lobby')
                            send_game_list()
                        else
                            p.socket = socket.id
                            game.save (err, game) ->
                                send_game_info(game, player_id)
                        return

                #Not in your current game
                socket.join('lobby')
                send_game_list()

    socket.on 'newgame', (game) ->
        socket.get 'player_id', (err, player_id) ->
            Player.findById player_id, (err, player) ->
                return if err || player == null
                game = new Game()
                game.add_player player
                game.save (err, game) ->
                    socket.leave('lobby')
                    socket.set('game', game._id)
                    player.currentGame = game._id
                    player.save()
                    send_game_list()
                    send_game_info(game)

    socket.on 'joingame', (data) ->
        game_id = data.game_id
        socket.get 'player_id', (err, player_id) ->
            Player.findById player_id, (err, player) ->
                return if not player
                if player.currentGame
                    player.currentGame = undefined
                    leave_game(player_id, player.currentGame)
                Game.findById game_id, (err, game) ->
                    return if not game
                    game.add_player player
                    #TODO check if player was actually added
                    game.save (err, game) ->
                        socket.leave('lobby')
                        socket.set('game', game._id)
                        player.currentGame = game._id
                        player.save()
                        send_game_list()
                        send_game_info(game)

    socket.on 'reconnecttogame', () ->
        socket.get 'player_id', (err, player_id) ->
            return if not player_id
            Player.findById player_id, (err, player) ->
                return if not player
                Game.findById player.currentGame, (err, game) ->
                    return if not game
                    socket.leave('lobby')
                    socket.set('game', game._id)
                    for p in game.players
                        if p.id.equals(player_id)
                            p.socket = socket.id
                            p.left = false
                    game.save (err, game) ->
                        send_game_info(game, player_id)

    socket.on 'ready', () ->
        socket.get 'game', (err, game_id) ->
            return if game_id == null
            Game.findById game_id, (err, game) ->
                if game.players[0].socket == socket.id
                    if game.players.length >= 5
                        game.state = GAME_PREGAME

                game.save()
                send_game_info(game)

    socket.on 'startgame', (data) ->
        socket.get 'game', (err, game_id) ->
            return if game_id == null
            Game.findById game_id, (err, game) ->
                order = data['order']
                game.gameOptions.mordred = data['options']['mordred']
                game.gameOptions.oberon = data['options']['oberon']
                game.gameOptions.showfails = data['options']['showfails']

                #Sanity check
                return if Object.keys(order).length + 1 != game.players.length

                start_game(game, order)

                game.save()
                send_game_info(game)

    socket.on 'propose_mission', (data) ->
        socket.get 'game', (err, game_id) ->
            return if game_id == null
            Game.findById game_id, (err, game) ->
                mission = game.missions[game.currentMission]
                return if data.length != mission.numReq
                game.votes.push
                    mission : game.currentMission
                    team    : data
                    votes   : []
                game.state = GAME_VOTE
                game.save()
                send_game_info(game)

    socket.on 'vote', (data) ->
        socket.get 'game', (err, game_id) ->
            return if game_id == undefined
            socket.get 'player_id', (err, player_id) ->
                return if player_id == undefined
                Game.findById game_id, (err, game) ->
                    return if not game
                    currVote = game.votes[game.votes.length - 1]

                    #Check to prevent double voting
                    for p in currVote.votes
                        voted = true if player_id.equals(p.id)
                    return if voted

                    currVote.votes.push
                        id      : player_id
                        vote    : data

                    #Check for vote end
                    if currVote.votes.length == game.players.length
                        vs = ((if v.vote then 1 else 0) for v in currVote.votes)
                        vs = vs.sum()
                        if vs > (game.players.length - vs)
                            game.state = GAME_QUEST
                        else
                            game.state = GAME_PROPOSE

                            #Check for too many failed votes
                            votecount = 0
                            for v in game.votes
                                if v.mission == game.currentMission
                                    votecount += 1

                            if votecount == 5
                                currMission = game.missions[game.currentMission]
                                currMission.status = 1
                                game.check_for_game_end()

                        game.set_next_leader()
                    game.save()
                    send_game_info(game)

    socket.on 'quest', (data) ->
        socket.get 'game', (err, game_id) ->
            return if game_id == undefined
            socket.get 'player_id', (err, player_id) ->
                return if player_id == undefined
                Game.findById game_id, (err, game) ->
                    return if not game
                    currVote = game.votes[game.votes.length - 1]

                    #Check that the player is on the mission team
                    for t in currVote.team
                        in_team = true if player_id.equals(t)
                    return if not in_team

                    #Check that the player hasn't already "put in a card"
                    currMission = game.missions[game.currentMission]
                    for p in currMission.players
                        return if player_id.equals(p.id)

                    #Check that player is allowed to fail if they did
                    if data == false
                        p = game.get_player(player_id)
                        if not p.isEvil
                            data = true

                    currMission.players.push
                        id          : player_id
                        success     : data

                    if currMission.players.length == currMission.numReq
                        #See if the mission succeeded or failed
                        fails = ((if p.success then 0 else 1) for p in currMission.players)
                        fails = fails.sum()
                        if fails >= currMission.failsReq
                            currMission.status = 1
                        else
                            currMission.status = 2

                        game.check_for_game_end()
                        game.save()
                        send_game_info(game)
                    else
                        game.save()

    socket.on 'assassinate', (t) ->
        socket.get 'game', (err, game_id) ->
            return if game_id == null
            Game.findById game_id, (err, game) ->
                return if game.state != GAME_ASSASSIN

                for p in game.players
                    if p.id.equals(t)
                        target = p
                        break

                return if target == null
                game.state = GAME_FINISHED
                game.assassinated = target.id
                if target.role == "Merlin"
                    game.evilWon = true
                else
                    game.evilWon = false

                game.save()
                send_game_info(game)

    socket.on 'leavegame', () ->
        socket.join('lobby')
        socket.get 'game', (err, game_id) ->
            return if not game_id
            socket.get 'player_id', (err, player_id) ->
                return if not player_id
                Game.findById game_id, (err, game) ->
                    return if not game
                    leave_game(player_id, game_id)
  
    socket.on 'disconnect', () ->
        #Do we need to do something here?
        return true
