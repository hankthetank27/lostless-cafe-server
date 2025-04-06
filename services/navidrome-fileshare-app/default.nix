{
  pkgs,
  config,
  storagePath,
  ...
}:
let
  checkAudioMetadata = pkgs.writeScriptBin "check-audio-metadata" (
    builtins.readFile ./check-audio-metadata.sh
  );

  convertToFlac = pkgs.writeScriptBin "convert-to-flac" (builtins.readFile ./convert-to-flac.sh);

  filebrowserDockerfile = pkgs.dockerTools.buildImage {
    name = "filebrowser-custom";
    tag = "latest";
    fromImage = pkgs.dockerTools.pullImage {
      # using my fork for the time being with bug fix for ignoring "Upload" hook.
      imageName = "hjackson277/filebrowser";
      imageDigest = "sha256:4530adc1e8188716393d839e61d2db6445ec60bf50d3b75d12ead070b28e99b1";
      sha256 = "sha256-OaYBHgUP5tDeisJTEmTbkmTI20K+ijJRP5ARY2Y1G5k=";
      finalImageName = "hjackson277/filebrowser";
      finalImageTag = "v1.0.0";
    };
    copyToRoot = pkgs.buildEnv {
      name = "image-root";
      paths = [
        pkgs.bash
        pkgs.ffmpeg
        checkAudioMetadata
        convertToFlac
      ];
      pathsToLink = [ "/bin" ];
    };
    config = {
      Cmd = [
        "/filebrowser"
        "-d"
        "/filebrowser.db"
      ];
      # for latest...
      # Cmd = [
      #   "/usr/bin/filebrowser"
      # ];
    };
  };

  composeFile = pkgs.writeTextFile {
    name = "compose.yml";
    text =
      #yaml
      ''
        services:
          navidrome:
            image: deluan/navidrome:latest
            container_name: navidrome
            restart: always
            environment:
              - ND_MUSICFOLDER=/music
              - ND_DATAFOLDER=/data
              - ND_UIWELCOMEMESSAGE=welcome..
              - ND_UILOGINBACKGROUNDURL=https://i.postimg.cc/ncxpBsSF/linux-bg.jpg
            volumes:
              - ${storagePath}/navidrome-fileshare-app/music:/music
              - ${storagePath}/navidrome-fileshare-app/navidrome-data:/data
            networks:
              - web
            ports:
              - 4533:4533
          filebrowser:
            image: filebrowser-custom
            container_name: filebrowser
            restart: always
            user: 1000:1000
            volumes:
              - ${storagePath}/navidrome-fileshare-app/music:/srv
              - ${storagePath}/navidrome-fileshare-app/filebrowser-config/database.db:/filebrowser.db
            networks:
              - web
            ports:
              - 8081:80
          cloudflared-tunnel:
             image: cloudflare/cloudflared:latest
             container_name: cloudflared-tunnel
             restart: unless-stopped
             environment:
              - TUNNEL_TOKEN=''${TUNNEL_TOKEN}
             command: tunnel run
             networks:
               - web
             depends_on:
               - navidrome
               - filebrowser
        networks:
          web:
            external: false
      '';
  };
in
{
  sops.secrets.navidrome-cloudflare-tunnel-token = {
    owner = "hjackson";
  };

  systemd.services.navidrome-fileshare-app = {
    requires = [
      "docker.service"
      "network-online.target"
    ];
    after = [
      "docker.service"
      "network-online.target"
    ];
    wantedBy = [ "multi-user.target" ];
    script = ''
      ${pkgs.docker}/bin/docker load < ${filebrowserDockerfile}
      ENV_FILE_TMP=/tmp/navidrome-cloudflared-tunnel-token
      echo -n "TUNNEL_TOKEN=" > $ENV_FILE_TMP && cat ${config.sops.secrets.navidrome-cloudflare-tunnel-token.path} | tr -d '\n' >> $ENV_FILE_TMP
      ${pkgs.docker}/bin/docker compose --env-file $ENV_FILE_TMP -f ${composeFile} up -d;
    '';
    serviceConfig = {
      User = "hjackson";
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStartPre = [ "${pkgs.docker}/bin/docker compose -f ${composeFile} down --remove-orphans" ];
      ExecStop = "${pkgs.docker}/bin/docker compose -f ${composeFile} down --remove-orphans";
      Restart = "on-failure";
    };
  };
}
