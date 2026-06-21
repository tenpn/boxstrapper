#!groovy
// boxstrapper admin bootstrap -- a Jenkins "Groovy hook script" that runs on every startup.
//
// Jenkins-Setup.ps1 copies this file UNCHANGED into <JENKINS_HOME>\init.groovy.d and supplies the
// credentials via the service's environment (JENKINS_ADMIN_USER / JENKINS_ADMIN_PASSWORD, set in
// jenkins.xml's <env> -- visible to the Jenkins process, so no machine-wide env var). No secret lives
// in this file; it is committed as-is. It no-ops when no password is present, so it is harmless on a
// box that has not opted into a seeded admin (and Jenkins-Setup removes it entirely in that case).
//
// secrets.ini is the source of truth: the password is re-applied on each boot, so a password changed
// in the UI reverts on restart -- rotate by editing secrets.ini and re-running Update-Box.ps1.

import jenkins.model.Jenkins
import hudson.security.HudsonPrivateSecurityRealm
import hudson.security.FullControlOnceLoggedInAuthorizationStrategy

def adminUser = System.getenv('JENKINS_ADMIN_USER') ?: 'admin'
def adminPass = System.getenv('JENKINS_ADMIN_PASSWORD')

if (adminPass) {
    def jenkins = Jenkins.get()

    def realm = jenkins.getSecurityRealm()
    if (!(realm instanceof HudsonPrivateSecurityRealm)) {
        realm = new HudsonPrivateSecurityRealm(false)
        jenkins.setSecurityRealm(realm)
    }
    // createAccount creates-or-overwrites the user, so the secrets.ini password always wins.
    realm.createAccount(adminUser, adminPass)

    if (!(jenkins.getAuthorizationStrategy() instanceof FullControlOnceLoggedInAuthorizationStrategy)) {
        def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
        strategy.setAllowAnonymousRead(false)
        jenkins.setAuthorizationStrategy(strategy)
    }

    jenkins.save()
}
