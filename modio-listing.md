<h2>Watchdog</h2>
<p>Watchdog builds alerts. An alert is a graph of nodes. A trigger watches the game. An action does something you can see or hear. Wire a trigger to an action and the action runs when the trigger does.</p>
<p>Open the manager with its key. The default key is F8. Clear that key on the settings page if you want F8 for something else. The Toggle button on the Watchdog content panel opens the manager too.</p>
<p>On the alert list, New alert starts a blank alert or copies a preset. Open an alert to edit its graph. Double-click empty space to add a node. Drag between the pins to connect them. Enable the alert in the list. A new alert starts enabled.</p>
<p>While you are in a restricted area, Watchdog will not alert you about nearby spawns, game messages, or walking into or out of a spot you chose. Other alerts still work.</p>
<p>A sound pack is another plugin registering builtin sounds. The Sound Effect node lists those sounds while that plugin is loaded. You can still type a builtin sound id by number.</p>
<h2>Feedback and collaboration</h2>
<p>Report bugs and suggestions at <a href="https://github.com/adamk33n3r/rs3-Watchdog/issues">https://github.com/adamk33n3r/rs3-Watchdog/issues</a>. Pull requests are welcome.</p>
<h2>EULA</h2>
<p>This Plugin uses software licensed by Jagex to the developer under the terms of the Jagex End User Licence Agreement (EULA) found at <a href="https://legal.jagex.com/docs/terms/eula">https://legal.jagex.com/docs/terms/eula</a> (and all terms incorporated into it by reference). The development and any use of the Plugin is at all times subject to the Jagex EULA.</p>
<h2>Permissions</h2>
<h3>chatAccess</h3>
<p>Watchdog requests chatAccess as an optional permission. The Game Message and Player Chat triggers read chat lines. The Game Message action adds a line to the chat window. Without this permission, those nodes do not run.</p>
<h3>trackingAccess</h3>
<p>Watchdog requests trackingAccess as an optional permission. Watchdog reads a tracking id and keeps alerts for that character. Without this permission, every character shares one alert list.</p>
<h3>Combined use</h3>
<p>Watchdog can hold chatAccess and trackingAccess at the same time. An alert saved for one character can use a chat node. The tracking id only selects which alerts load. Watchdog does not store a chat line with that id, and it sends nothing off the machine.</p>
<h2>Data Protection</h2>
<p>Watchdog stores alert graphs, alert names, presets, the manager key, the position lock, the on-screen positions of infoboxes and toasts, which release notes you have dismissed, and the result of the last import or export. If tracking permission is on, it also stores a tracking id so alerts can be kept per character. These plugin settings are kept between sessions.</p>
<p>While you play, Watchdog reads your tile, your life points, prayer points, summoning points, and adrenaline, your skill levels and XP, and the item names and counts in your inventory and your bank. It reads the name and tile of nearby NPCs, players, and objects when they appear or disappear. With chat permission, it reads chat lines and the sender's name. It uses that information to decide whether an alert fires. Game information is not stored between sessions.</p>
<p>The Game Message action adds a line to your own chat window. That line stays on this client. If the Shortest Path plugin is installed, Watchdog can hand it a start tile and an end tile so that plugin can draw a path. Those tiles stay on this machine. Names and tiles of other players are used only to match an alert. They are not exported.</p>
<p>This information is not transmitted outside of the plugin under any circumstances.</p>
