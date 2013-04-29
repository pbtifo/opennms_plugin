Installation du plugin OpenNMS

1- Copier le contenu du dossier plugin dans le dossier spécifié par le paramètre libdir dans ikiwiki.setup. Exemple:
   cp -r plugin/* /home/r-wiki/.ikiwiki
2- Ajouter les information de configurations relatives au plugin dans ikiwiki.setup:
   ikiwiki --changesetup ikiwiki.setup --plugin opennms_mon
3- Spécifier les adresses et les authentifications des serveurs OpenNMS actifs (dans la section opennms_mon du nouveau ikiwiki.setup)
4- Recompiler le wiki
   ikiwiki --setup ikiwiki.setup
