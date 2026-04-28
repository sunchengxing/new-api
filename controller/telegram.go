package controller

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"

	"github.com/QuantumNous/new-api/common"
	"github.com/QuantumNous/new-api/model"

	"github.com/gin-contrib/sessions"
	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

func TelegramBind(c *gin.Context) {
	if !common.TelegramOAuthEnabled {
		c.JSON(200, gin.H{
			"message": "管理员未开启通过 Telegram 登录以及注册",
			"success": false,
		})
		return
	}
	params := c.Request.URL.Query()
	if !checkTelegramAuthorization(params, common.TelegramBotToken) {
		c.JSON(200, gin.H{
			"message": "无效的请求",
			"success": false,
		})
		return
	}
	telegramId := params["id"][0]
	if model.IsTelegramIdAlreadyTaken(telegramId) {
		c.JSON(200, gin.H{
			"message": "该 Telegram 账户已被绑定",
			"success": false,
		})
		return
	}

	session := sessions.Default(c)
	id := session.Get("id")
	user := model.User{Id: id.(int)}
	if err := user.FillUserById(); err != nil {
		c.JSON(200, gin.H{
			"message": err.Error(),
			"success": false,
		})
		return
	}
	if user.Id == 0 {
		c.JSON(http.StatusOK, gin.H{
			"success": false,
			"message": "用户已注销",
		})
		return
	}
	user.TelegramId = telegramId
	if err := user.Update(false); err != nil {
		c.JSON(200, gin.H{
			"message": err.Error(),
			"success": false,
		})
		return
	}

	c.Redirect(302, "/console/personal")
}

func TelegramLogin(c *gin.Context) {
	if !common.TelegramOAuthEnabled {
		c.JSON(200, gin.H{
			"message": "管理员未开启通过 Telegram 登录以及注册",
			"success": false,
		})
		return
	}
	params := c.Request.URL.Query()
	if !checkTelegramAuthorization(params, common.TelegramBotToken) {
		c.JSON(200, gin.H{
			"message": "无效的请求",
			"success": false,
		})
		return
	}

	telegramId := params["id"][0]
	user := model.User{TelegramId: telegramId}
	if model.IsTelegramIdAlreadyTaken(telegramId) {
		if err := user.FillUserByTelegramId(); err != nil {
			c.JSON(200, gin.H{
				"message": err.Error(),
				"success": false,
			})
			return
		}
	} else {
		if !common.RegisterEnabled {
			c.JSON(http.StatusOK, gin.H{
				"message": "管理员关闭了新用户注册",
				"success": false,
			})
			return
		}
		inviteCode := strings.TrimSpace(params.Get("invite_code"))
		user.Username = "telegram_" + strconv.Itoa(model.GetMaxUserId()+1)
		if username := strings.TrimSpace(params.Get("username")); username != "" {
			user.DisplayName = username
		} else {
			user.DisplayName = strings.TrimSpace(fmt.Sprintf("%s %s", params.Get("first_name"), params.Get("last_name")))
			if user.DisplayName == "" {
				user.DisplayName = "Telegram User"
			}
		}
		user.Role = common.RoleCommonUser
		user.Status = common.UserStatusEnabled
		if err := model.DB.Transaction(func(tx *gorm.DB) error {
			if err := user.InsertWithTx(tx, 0); err != nil {
				return err
			}
			if err := tx.Model(&user).Update("telegram_id", telegramId).Error; err != nil {
				return err
			}
			user.TelegramId = telegramId
			if common.InviteCodeRegisterEnabled {
				if inviteCode == "" {
					return fmt.Errorf("请输入邀请码")
				}
				return model.ConsumeInviteCodeTx(tx, inviteCode, user.Id, user.Username)
			}
			return nil
		}); err != nil {
			c.JSON(http.StatusOK, gin.H{
				"message": err.Error(),
				"success": false,
			})
			return
		}
		user.FinalizeOAuthUserCreation(0)
	}
	setupLogin(&user, c)
}

func checkTelegramAuthorization(params map[string][]string, token string) bool {
	strs := []string{}
	var hash = ""
	for k, v := range params {
		if k == "hash" {
			hash = v[0]
			continue
		}
		if k == "invite_code" || k == "aff" {
			continue
		}
		strs = append(strs, k+"="+v[0])
	}
	sort.Strings(strs)
	var imploded = ""
	for _, s := range strs {
		if imploded != "" {
			imploded += "\n"
		}
		imploded += s
	}
	sha256hash := sha256.New()
	io.WriteString(sha256hash, token)
	hmachash := hmac.New(sha256.New, sha256hash.Sum(nil))
	io.WriteString(hmachash, imploded)
	ss := hex.EncodeToString(hmachash.Sum(nil))
	return hash == ss
}
