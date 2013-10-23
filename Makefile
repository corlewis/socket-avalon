SERVERSRC = server/config.coffee server/server.coffee server/db.coffee server/avalon.coffee
SERVER = avalon.js

CLIENTSRC = server/config.coffee client/client.coffee
CLIENT = js/avalon.js

.PHONY: all
all: $(SERVER) $(CLIENT)

$(CLIENT): $(CLIENTSRC)
	coffee -j $(CLIENT) -c $(CLIENTSRC)

$(SERVER): $(SERVERSRC)
	coffee -j $(SERVER) -c $(SERVERSRC)

clean:
	rm -rf $(CLIENT) $(SERVER)

